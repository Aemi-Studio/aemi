//
//  Throttler.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 15/02/25.
//

import Foundation

public actor Throttler<S, F> where S: Sendable, F: Error {
    public typealias Job = DependantTask<S, F>

    private var task: Job?
    private let interval: TimeInterval
    private var lastExecutionEndTime: TimeInterval = Date.distantPast.timeIntervalSinceReferenceDate

    public init(interval: TimeInterval) where S == Void, F == Never {
        self.interval = interval
    }

    public func callAsFunction(_ operation: @escaping Job.Operation) async -> Job? where S == Void, F == Never {
        if let task = await task?.last() {
            self.task = await task.attach { [weak self] in
                guard let self else { return }
                await delayIfNeeded()
                operation()
                await updateLastExecutionEndTime()
            }
        } else {
            task = Job { [weak self] in
                guard let self else { return }
                await delayIfNeeded()
                operation()
                await updateLastExecutionEndTime()
            }
        }
        return task
    }

    public func callAsFunction(_ operation: @escaping Job.AsyncOperation) async -> Job? where S == Void, F == Never {
        if let task = await task?.last() {
            self.task = await task.attach { [weak self] in
                guard let self else { return }
                await delayIfNeeded()
                await operation()
                await updateLastExecutionEndTime()
            }
        } else {
            task = Job { [weak self] in
                guard let self else { return }
                await delayIfNeeded()
                await operation()
                await updateLastExecutionEndTime()
            }
        }
        return task
    }
}

extension Throttler {
    private func delayIfNeeded() async {
        let now = Date().timeIntervalSinceReferenceDate
        let timeSinceLastExecution = now - lastExecutionEndTime
        let timeToNextExecution = interval - timeSinceLastExecution

        if timeToNextExecution > 0 {
            try? await Task.sleep(for: .milliseconds(timeToNextExecution * 1000))
        }
    }

    private func updateLastExecutionEndTime() async {
        lastExecutionEndTime = Date().timeIntervalSinceReferenceDate
    }
}
