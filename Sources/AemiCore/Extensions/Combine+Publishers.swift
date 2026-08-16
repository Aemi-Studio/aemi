//
//  Combine+Publishers.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 04/02/25.
//

@preconcurrency import Combine
import Foundation

public extension Publisher where Failure == Never, Output: Sendable {
    var stream: AsyncStream<Output> {
        AsyncStream { continuation in
            let cancellable = sink { completion in
                switch completion {
                case .finished:
                    continuation.finish()
                }
            } receiveValue: { value in
                continuation.yield(value)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    func stream(
        on scheduler: some Scheduler = DispatchQueue.main,
        onFinish: @Sendable @escaping (AsyncStream<Output>.Continuation.Termination) -> Void = { _ in },
        onCancellation: @Sendable @escaping (AsyncStream<Output>.Continuation.Termination) -> Void = { _ in }
    ) -> AsyncStream<Output> where Output: Sendable {
        AsyncStream { continuation in
            let cancellable = receive(on: scheduler)
                .sink { completion in
                    switch completion {
                    case .finished:
                        continuation.finish()
                    }
                } receiveValue: { value in
                    scheduler.schedule {
                        continuation.yield(value)
                    }
                }

            continuation.onTermination = { termination in
                switch termination {
                case .finished: onFinish(termination)
                case .cancelled: onCancellation(termination)
                @unknown default: break
                }
                cancellable.cancel()
            }
        }
    }
}
