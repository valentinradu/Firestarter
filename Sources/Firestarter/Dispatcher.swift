//
//  File.swift
//
//
//  Created by Valentin Radu on 17/10/2021.
//

import Combine

/**
 The dispatcher propagates actions to workers.
 Its main jobs are:
    - to register workers
    - to register middlewares
    - to fire actions
    - to handle redirections

 - note: All the async `fire` operations also have `Combine`, `async/await` and legacy callback closures support.
 */
public class Dispatcher {
    public typealias Completion = (Result<Void, Error>) -> Void

    /// All the actions fired since the dispatcher was initiated or reseted
    public private(set) var history: ActionFlow<AnyAction> = .empty()

    private var _workers: [AnyWorker] = []
    private var _middlewares: [AnyMiddleware] = []
    private var _cancellables: Set<AnyCancellable> = []

    /**
     Registers a new middleware.
     - parameter middleware: The middleware instance to register
     - seealso: Middleware
     */
    public func register<M: Middleware>(middleware: M) {
        _middlewares.append(AnyMiddleware(middleware))
    }

    /**
     Registers a new worker
     - parameter worker: The worker instance to register
     - seealso: Worker
     */
    public func register<W: Worker>(worker: W) {
        _workers.append(AnyWorker(worker))
    }

    /**
     Resets the dispatcher to its initial state, stopping any current action processing and optionally unregistering the workers, middleware and clearing the history.
     */
    public func reset(history: Bool = false,
                      workers: Bool = false,
                      middlewares: Bool = false)
    {
        _cancellables = []
        if history {
            self.history = .empty()
        }
        if workers {
            _workers = []
        }
        if middlewares {
            _middlewares = []
        }
    }

    /**
     Fires an action and calls back a completion handler when the action has been processed by all the workers.
        - parameter action: The action
     */
    func fire<A: Action>(_ action: A,
                         completion: Completion?)
    {
        _fire(action)
            .sink(
                receiveCompletion: { result in
                    switch result {
                    case let .failure(error):
                        completion?(.failure(error))
                    case .finished:
                        break
                    }
                },
                receiveValue: { result in
                    completion?(.success(result))
                }
            )
            .store(in: &_cancellables)
    }

    /**
     Fires an action flow (multiple actions chained one after the other) and calls back a completion handler when the it has been processed by all the workers. If any of the workers throws an error, the chain is interruped and the remaining actions are not processed.
        - parameter flow: The action flow
     */
    public func fire<A: Action>(_ flow: ActionFlow<A>,
                                completion: Completion?)
    {
        _fire(flow)
            .sink(
                receiveCompletion: { result in
                    switch result {
                    case let .failure(error):
                        completion?(.failure(error))
                    case .finished:
                        break
                    }
                },
                receiveValue: { result in
                    completion?(.success(result))
                }
            )
            .store(in: &_cancellables)
    }

    /**
     Fires an action and returns a publisher that completes (or errors out) when all the workers finished processing the action.
        - parameter action: The action
     */
    public func fire<A: Action>(_ action: A) -> AnyPublisher<Void, Error> {
        _fire(action)
    }

    /**
      Fires an action flow (multiple actions chained one after the other) and returns a publisher that completes (or errors out) when all the workers finished processing the actions. If any of the workers throws an error, the chain is interruped and the remaining actions are not processed anymore.
         - parameter flow: The action flow
     */
    public func fire<A: Action>(_ flow: ActionFlow<A>) -> AnyPublisher<Void, Error> {
        _fire(flow)
    }

    /**
     Similar to the other `fire(action:)` methods, except completion is ignored.
         - parameter action: The action
         - seealso: fire(action:)
     */
    public func fireAndForget<A: Action>(_ action: A) {
        fire(action, completion: nil)
    }

    /**
     Similar to the other `fire(flow:)` methods, except completion is ignored.
        - parameter flow: The action flow
        - seealso: fire(flow:)
     */
    public func fireAndForget<A: Action>(_ flow: ActionFlow<A>) {
        fire(flow, completion: nil)
    }

    /**
     Fires an action using `async/await`
     */
    @available(iOS 15.0, macOS 12.0, watchOS 8.0, tvOS 15.0, *)
    public func fire<A: Action>(_ action: A) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            fire(action) {
                switch $0 {
                case .success:
                    continuation.resume(returning: ())
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /**
     Fires an action flow using `async/await`
     */
    @available(iOS 15.0, macOS 12.0, watchOS 8.0, tvOS 15.0, *)
    public func fire<A: Action>(_ flow: ActionFlow<A>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            fire(flow) {
                switch $0 {
                case .success:
                    continuation.resume(returning: ())
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension Dispatcher {
    func _fire<A: Action>(_ action: A) -> AnyPublisher<Void, Error> {
        _fire(.init(actions: [action]))
    }

    func _fire<A: Action>(_ flow: ActionFlow<A>) -> AnyPublisher<Void, Error> {
        var pub = Just(())
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()

        var stack = Array(
            flow.actions
                .map { AnyAction($0) }
        )

        while !stack.isEmpty {
            let action = stack.removeFirst()
            pub = pub
                .flatMap { [self] () -> AnyPublisher<Void, Error> in
                    for middleware in _middlewares {
                        do {
                            let rewrite = try middleware.pre(action: AnyAction(action))

                            switch rewrite {
                            case let .redirect(otherFlow):
                                let actions = otherFlow.actions + stack
                                return _fire(.init(actions: actions))
                            case .none:
                                continue
                            }
                        } catch {
                            for middleware in _middlewares {
                                middleware.failure(action: action,
                                                   error: error)
                            }
                            return Fail(outputType: Void.self,
                                        failure: error)
                                .eraseToAnyPublisher()
                        }
                    }

                    var workerPubs: [AnyPublisher<Void, Error>] = []
                    for worker in _workers {
                        workerPubs.append(
                            worker.execute(action)
                                .handleEvents(receiveCompletion: { [self] result in
                                    switch result {
                                    case let .failure(error):
                                        for middleware in _middlewares {
                                            middleware.failure(action: action, error: error)
                                        }
                                    case .finished:
                                        break
                                    }
                                })
                                .flatMap {
                                    _fire($0)
                                }
                                .share()
                                .eraseToAnyPublisher()
                        )
                    }

                    return Publishers.MergeMany(workerPubs)
                        .collect()
                        .map { _ in () }
                        .flatMap {
                            Future<Void, Error> { promise in
                                self.history = self.history.then(action)

                                for middleware in self._middlewares {
                                    middleware.post(action: action)
                                }

                                promise(.success(()))
                            }
                            .eraseToAnyPublisher()
                        }
                        .share()
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }

        return pub
    }
}