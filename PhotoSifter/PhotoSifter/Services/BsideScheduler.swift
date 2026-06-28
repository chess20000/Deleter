import Foundation

/// Adaptive background scheduler for bside compression jobs.
///
/// Concurrency is bounded by a dynamic ceiling that responds to system load:
///   - Thermal state: nominal/fair → baseline, serious → half, critical → 1
///   - CPU usage: sustained high → reduce; sustained low → restore baseline
/// New jobs beyond the ceiling are queued (FIFO). Running jobs are never
/// preempted; they simply drain as the ceiling lowers.
actor BsideScheduler {

    struct Progress {
        var completed: Int = 0
        var total: Int = 0
        var running: Int = 0
        var queued: Int = 0
        var currentName: String? = nil
        var failed: Int = 0

        var fraction: Double {
            total == 0 ? 0 : Double(completed) / Double(total)
        }
        var isIdle: Bool { running == 0 && queued == 0 }
    }

    private struct QueuedJob {
        let id: UUID
        let work: () async -> Void
        let displayName: String
    }

    private var queue: [QueuedJob] = []
    private var runningCount: Int = 0
    private(set) var progress = Progress()
    /// Task handles for currently-running jobs, keyed by job id. Lets us
    /// cancel a job mid-flight (not just dequeue it) when the user unmarks it.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private let baseline: Int
    private var maxConcurrency: Int
    private var highCpuStreak = 0
    private var lowCpuStreak = 0

    private var cpuSampler: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var progressContinuations: [UUID: AsyncStream<Progress>.Continuation] = [:]

    init() {
        let cores = max(2, min(8, ProcessInfo.processInfo.processorCount))
        self.baseline = cores
        self.maxConcurrency = cores
        // Monitoring setup happens after init so we can touch actor-isolated
        // state safely.
    }

    deinit {
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        cpuSampler?.cancel()
    }

    // MARK: - Public

    /// Enqueue a compression job. Returns the job id.
    @discardableResult
    func enqueue(
        id: UUID,
        displayName: @autoclosure @escaping () -> String,
        work: @escaping () async -> Void
    ) async -> UUID {
        // Lazy one-time monitoring start.
        if cpuSampler == nil { startMonitoring() }
        progress.total += 1
        progress.queued += 1
        let job = QueuedJob(id: id, work: work, displayName: displayName())
        queue.append(job)
        pump()
        return id
    }

    /// Cancel a queued job (no-op if already running/completed).
    func cancelQueued(id: UUID) {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: idx)
            progress.queued = max(0, progress.queued - 1)
            progress.total = max(0, progress.total - 1)
            broadcastProgress()
        }
    }

    func observeProgress() -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let token = UUID()
            self.progressContinuations[token] = continuation
            continuation.yield(self.progress)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    private func removeContinuation(_ token: UUID) {
        progressContinuations[token] = nil
    }

    private func broadcastProgress() {
        for (_, c) in progressContinuations { c.yield(progress) }
    }

    // MARK: - Pumping

    private func pump() {
        guard !queue.isEmpty else { return }
        while runningCount < maxConcurrency && !queue.isEmpty {
            let job = queue.removeFirst()
            runningCount += 1
            progress.queued = max(0, progress.queued - 1)
            progress.running = runningCount
            progress.currentName = job.displayName
            broadcastProgress()
            let capturedName = job.displayName
            let task = Task(priority: .utility) { [weak self] in
                await job.work()
                await self?.complete(jobId: job.id, currentName: capturedName)
            }
            runningTasks[job.id] = task
        }
    }

    private func complete(jobId: UUID, currentName: String) {
        runningCount -= 1
        progress.running = runningCount
        progress.completed += 1
        runningTasks[jobId] = nil
        if progress.queued > 0 {
            progress.currentName = queue.first?.displayName
        } else if runningCount == 0 {
            progress.currentName = nil
        }
        _ = jobId
        _ = currentName
        broadcastProgress()
        pump()
    }

    /// Cancel a job that is currently running. Cooperative: signals the task,
    /// which is expected to observe `Task.isCancelled` in its work and bail
    /// out. No-op if the job isn't running (already finished or still queued —
    /// use `cancelQueued` for the latter). The job still counts as completed
    /// once its work returns.
    func cancelRunning(id: UUID) {
        if let task = runningTasks[id] {
            task.cancel()
            // Leave the entry; complete() will clear it when work returns.
        }
    }

    // MARK: - Monitoring (thermal + CPU)

    private func startMonitoring() {
        // Thermal observer.
        let observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.applyThermalState() }
        }
        thermalObserver = observer
        ThermalObserverHolder.shared.set(observer)

        // CPU sampler task.
        cpuSampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.sampleCPU()
            }
        }
    }

    private func applyThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal, .fair:
            maxConcurrency = baseline
        case .serious:
            maxConcurrency = max(1, (baseline + 1) / 2)
        case .critical:
            maxConcurrency = 1
        @unknown default:
            maxConcurrency = max(1, baseline / 2)
        }
        pump()
    }

    private func sampleCPU() {
        let usage = CPUMonitor.overallUsage()
        if usage > 0.88 {
            highCpuStreak += 1
            lowCpuStreak = 0
            if highCpuStreak >= 2 && maxConcurrency > 1 {
                maxConcurrency -= 1
            }
        } else if usage < 0.50 {
            lowCpuStreak += 1
            highCpuStreak = 0
            if lowCpuStreak >= 2 && maxConcurrency < baseline {
                maxConcurrency += 1
            }
        } else {
            highCpuStreak = 0
            lowCpuStreak = 0
        }
    }
}

/// Holds the thermal observer so it can be referenced for cleanup.
final class ThermalObserverHolder {
    static let shared = ThermalObserverHolder()
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private let lock = NSLock()

    func set(_ o: NSObjectProtocol) {
        lock.lock(); observers[ObjectIdentifier(self)] = o; lock.unlock()
    }
}

/// Samples overall system CPU usage via host_processor_info.
enum CPUMonitor {
    static func overallUsage() -> Double {
        var procCount: natural_t = 0
        var cpuInfo: processor_info_array_t? = nil
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &procCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<Int32>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var totalTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        // processor_info_array_t is a flat Int32 buffer; each CPU occupies
        // 4 consecutive Int32s (user, system, idle, nice). The values are
        // logically unsigned, so reinterpret via UInt32(bitPattern:).
        let ticksPerCPU = 4
        for i in 0..<Int(procCount) {
            let base = i * ticksPerCPU
            let user = UInt64(UInt32(bitPattern: info[base]))
            let system = UInt64(UInt32(bitPattern: info[base + 1]))
            let idle = UInt64(UInt32(bitPattern: info[base + 2]))
            let nice = UInt64(UInt32(bitPattern: info[base + 3]))
            totalTicks += user + system + idle + nice
            idleTicks += idle
        }
        guard totalTicks > 0 else { return 0 }
        return 1.0 - Double(idleTicks) / Double(totalTicks)
    }
}
