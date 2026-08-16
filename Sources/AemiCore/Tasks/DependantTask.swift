//
//  DependantTask.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 15/02/25.
//

import Foundation

public actor DependantTask<Success, Failure>: Identifiable where Success: Sendable, Failure: Error {
    public typealias ID = UUID
    public typealias Job = Task<Success, Failure>
    public typealias Operation = @Sendable () -> Success
    public typealias AsyncOperation = @Sendable () async -> Success

    public let id: ID = .init()
    private var work: Job?
    private(set) weak var previous: DependantTask<Success, Failure>?
    private(set) var next: DependantTask<Success, Failure>?

    public func last() async -> DependantTask<Success, Failure>? {
        await next?.last() ?? next ?? self
    }

    public func result() async -> Result<Success, Failure>? {
        await work?.result
    }

    public func value() async -> Success? {
        try? await work?.value
    }

    public func isCancelled() -> Bool {
        work?.isCancelled ?? false
    }

    private func cleanup() async {
        await previous?.cleanup()
        previous = nil
    }

    public init() {}

    public init(
        previous: DependantTask<Success, Failure>? = nil,
        operation: @escaping Operation
    ) where Success == Void, Failure == Never {
        self.previous = previous
        work = Task { [unowned previous] in
            if let previous, await !previous.isCancelled() {
                _ = await previous.value()
            }
            operation()
        }
        Task.detached { [weak self] in
            guard let self else { return }
            await work?.value
            await cleanup()
        }
    }

    public init(
        previous: DependantTask<Success, Failure>? = nil,
        operation: @escaping AsyncOperation
    ) where Success == Void, Failure == Never {
        self.previous = previous
        work = Task { [unowned previous] in
            if let previous, await !previous.isCancelled() {
                _ = await previous.value()
            }
            await operation()
        }
        Task.detached { [weak self] in
            guard let self else { return }
            await work?.value
            await cleanup()
        }
    }

    public func attach(_ operation: @escaping Operation) async -> DependantTask? where Success == Void, Failure == Never {
        if next == nil {
            next = DependantTask(previous: self, operation: operation)
            return next
        }
        return await next?.attach(operation)
    }

    public func attach(_ operation: @escaping AsyncOperation) async -> DependantTask? where Success == Void, Failure == Never {
        if next == nil {
            next = DependantTask(previous: self, operation: operation)
            return next
        }
        return await next?.attach(operation)
    }

    public func cancel() {
        work?.cancel()
        Task {
            await previous?.cancel()
        }
    }
}
