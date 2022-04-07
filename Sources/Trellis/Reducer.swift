//
//  File.swift
//
//
//  Created by Valentin Radu on 04/04/2022.
//

import Foundation

class Store<State> {
    private(set) var state: State

    init(initialState: State) {
        state = initialState
    }

    @MainActor func update<T>(_ closure: (inout State) -> T) -> T {
        closure(&state)
    }
}

public struct EmptyContext {}

public struct EmptyState {}

public struct Reducer<S, C, A>: Service where A: Action {
    public typealias SideEffect<C> = (Dispatch, C) async throws -> Void
    public typealias Reduce = (inout S, A) -> SideEffect<C>?
    private let _store: Store<S>
    private let _context: C
    private let _reduce: Reduce
    @Environment(\.dispatch) private var _dispatch

    public init(reduce: @escaping Reduce)
        where S == EmptyState, C == EmptyContext
    {
        let state = EmptyState()
        let context = EmptyContext()
        _store = Store(initialState: state)
        _reduce = reduce
        _context = context
    }

    public init(initialState state: S, reduce: @escaping Reduce)
        where C == EmptyContext
    {
        let context = EmptyContext()
        _store = Store(initialState: state)
        _reduce = reduce
        _context = context
    }

    public init(context: C, reduce: @escaping Reduce)
        where S == EmptyState
    {
        let state = EmptyState()
        _store = Store(initialState: state)
        _reduce = reduce
        _context = context
    }

    public init(state: S, context: C, reduce: @escaping Reduce) {
        _store = Store(initialState: state)
        _reduce = reduce
        _context = context
    }

    public var body: some Service {
        EmptyService()
    }

    public func receive(action: any Action) async throws {
        guard let action = action as? A else {
            return
        }

        let sideEffect = await _store.update {
            _reduce(&$0, action)
        }

        if let sideEffect = sideEffect {
            try await sideEffect(_dispatch, _context)
        }
    }
}
