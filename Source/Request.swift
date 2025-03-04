//
//  Request.swift
//
//  Copyright (c) 2014-2020 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// `Request` is the common superclass of all Alamofire request types and provides common state, delegate, and callback
/// handling.
public class Request {
    /// State of the `Request`, with managed transitions between states set when calling `resume()`, `suspend()`, or
    /// `cancel()` on the `Request`.
    public enum State {
        /// Initial state of the `Request`.
        case initialized
        /// `State` set when `resume()` is called. Any tasks created for the `Request` will have `resume()` called on
        /// them in this state.
        case resumed
        /// `State` set when `suspend()` is called. Any tasks created for the `Request` will have `suspend()` called on
        /// them in this state.
        case suspended
        /// `State` set when `cancel()` is called. Any tasks created for the `Request` will have `cancel()` called on
        /// them. Unlike `resumed` or `suspended`, once in the `cancelled` state, the `Request` can no longer transition
        /// to any other state.
        case cancelled
        /// `State` set when all response serialization completion closures have been cleared on the `Request` and
        /// enqueued on their respective queues.
        case finished

        /// Determines whether `self` can be transitioned to the provided `State`.
        func canTransitionTo(_ state: State) -> Bool {
            switch (self, state) {
            case (.initialized, _):
                return true
            case (_, .initialized), (.cancelled, _), (.finished, _):
                return false
            case (.resumed, .cancelled), (.suspended, .cancelled), (.resumed, .suspended), (.suspended, .resumed):
                return true
            case (.suspended, .suspended), (.resumed, .resumed):
                return false
            case (_, .finished):
                return true
            }
        }
    }

    // MARK: - Initial State

    /// `UUID` providing a unique identifier for the `Request`, used in the `Hashable` and `Equatable` conformances.
    public let id: UUID
    /// The serial queue for all internal async actions.
    public let underlyingQueue: DispatchQueue
    /// The queue used for all serialization actions. By default it's a serial queue that targets `underlyingQueue`.
    public let serializationQueue: DispatchQueue
    /// `EventMonitor` used for event callbacks.
    public let eventMonitor: EventMonitor?
    /// The `Request`'s interceptor.
    public let interceptor: RequestInterceptor?
    /// The `Request`'s delegate.
    public private(set) weak var delegate: RequestDelegate?

    // MARK: - Mutable State

    /// Type encapsulating all mutable state that may need to be accessed from anything other than the `underlyingQueue`.
    struct MutableState {
        /// State of the `Request`.
        var state: State = .initialized
        /// `ProgressHandler` and `DispatchQueue` provided for upload progress callbacks.
        var uploadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)?
        /// `ProgressHandler` and `DispatchQueue` provided for download progress callbacks.
        var downloadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)?
        /// `RedirectHandler` provided for to handle request redirection.
        var redirectHandler: RedirectHandler?
        /// `CachedResponseHandler` provided to handle response caching.
        var cachedResponseHandler: CachedResponseHandler?
        /// Queue and closure called when the `Request` is able to create a cURL description of itself.
        var cURLHandler: (queue: DispatchQueue, handler: (String) -> Void)?
        /// Queue and closure called when the `Request` creates a `URLRequest`.
        var urlRequestHandler: (queue: DispatchQueue, handler: (URLRequest) -> Void)?
        /// Queue and closure called when the `Request` creates a `URLSessionTask`.
        var urlSessionTaskHandler: (queue: DispatchQueue, handler: (URLSessionTask) -> Void)?
        /// Response serialization closures that handle response parsing.
        var responseSerializers: [() -> Void] = []
        /// Response serialization completion closures executed once all response serializers are complete.
        var responseSerializerCompletions: [() -> Void] = []
        /// Whether response serializer processing is finished.
        var responseSerializerProcessingFinished = false
        /// `URLCredential` used for authentication challenges.
        var credential: URLCredential?
        /// All `URLRequest`s created by Alamofire on behalf of the `Request`.
        var requests: [URLRequest] = []
        /// All `URLSessionTask`s created by Alamofire on behalf of the `Request`.
        var tasks: [URLSessionTask] = []
        /// All `URLSessionTaskMetrics` values gathered by Alamofire on behalf of the `Request`. Should correspond
        /// exactly the the `tasks` created.
        var metrics: [URLSessionTaskMetrics] = []
        /// Number of times any retriers provided retried the `Request`.
        var retryCount = 0
        /// Final `AFError` for the `Request`, whether from various internal Alamofire calls or as a result of a `task`.
        var error: AFError?
        /// Whether the instance has had `finish()` called and is running the serializers. Should be replaced with a
        /// representation in the state machine in the future.
        var isFinishing = false
        /// Actions to run when requests are finished. Use for concurrency support.
        var finishHandlers: [() -> Void] = []
    }

    /// Protected `MutableState` value that provides thread-safe access to state values.
    fileprivate let mutableState = Protected(MutableState())

    /// `State` of the `Request`.
    public var state: State { mutableState.state }
    /// Returns whether `state` is `.initialized`.
    public var isInitialized: Bool { state == .initialized }
    /// Returns whether `state is `.resumed`.
    public var isResumed: Bool { state == .resumed }
    /// Returns whether `state` is `.suspended`.
    public var isSuspended: Bool { state == .suspended }
    /// Returns whether `state` is `.cancelled`.
    public var isCancelled: Bool { state == .cancelled }
    /// Returns whether `state` is `.finished`.
    public var isFinished: Bool { state == .finished }

    // MARK: Progress

    /// Closure type executed when monitoring the upload or download progress of a request.
    public typealias ProgressHandler = (Progress) -> Void

    /// `Progress` of the upload of the body of the executed `URLRequest`. Reset to `0` if the `Request` is retried.
    public let uploadProgress = Progress(totalUnitCount: 0)
    /// `Progress` of the download of any response data. Reset to `0` if the `Request` is retried.
    public let downloadProgress = Progress(totalUnitCount: 0)
    /// `ProgressHandler` called when `uploadProgress` is updated, on the provided `DispatchQueue`.
    private var uploadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)? {
        get { mutableState.uploadProgressHandler }
        set { mutableState.uploadProgressHandler = newValue }
    }

    /// `ProgressHandler` called when `downloadProgress` is updated, on the provided `DispatchQueue`.
    fileprivate var downloadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)? {
        get { mutableState.downloadProgressHandler }
        set { mutableState.downloadProgressHandler = newValue }
    }

    // MARK: Redirect Handling

    /// `RedirectHandler` set on the instance.
    public private(set) var redirectHandler: RedirectHandler? {
        get { mutableState.redirectHandler }
        set { mutableState.redirectHandler = newValue }
    }

    // MARK: Cached Response Handling

    /// `CachedResponseHandler` set on the instance.
    public private(set) var cachedResponseHandler: CachedResponseHandler? {
        get { mutableState.cachedResponseHandler }
        set { mutableState.cachedResponseHandler = newValue }
    }

    // MARK: URLCredential

    /// `URLCredential` used for authentication challenges. Created by calling one of the `authenticate` methods.
    public private(set) var credential: URLCredential? {
        get { mutableState.credential }
        set { mutableState.credential = newValue }
    }

    // MARK: Validators

    /// `Validator` callback closures that store the validation calls enqueued.
    fileprivate let validators = Protected<[() -> Void]>([])

    // MARK: URLRequests

    /// All `URLRequests` created on behalf of the `Request`, including original and adapted requests.
    public var requests: [URLRequest] { mutableState.requests }
    /// First `URLRequest` created on behalf of the `Request`. May not be the first one actually executed.
    public var firstRequest: URLRequest? { requests.first }
    /// Last `URLRequest` created on behalf of the `Request`.
    public var lastRequest: URLRequest? { requests.last }
    /// Current `URLRequest` created on behalf of the `Request`.
    public var request: URLRequest? { lastRequest }

    /// `URLRequest`s from all of the `URLSessionTask`s executed on behalf of the `Request`. May be different from
    /// `requests` due to `URLSession` manipulation.
    public var performedRequests: [URLRequest] { mutableState.read { $0.tasks.compactMap(\.currentRequest) } }

    // MARK: HTTPURLResponse

    /// `HTTPURLResponse` received from the server, if any. If the `Request` was retried, this is the response of the
    /// last `URLSessionTask`.
    public var response: HTTPURLResponse? { lastTask?.response as? HTTPURLResponse }

    // MARK: Tasks

    /// All `URLSessionTask`s created on behalf of the `Request`.
    public var tasks: [URLSessionTask] { mutableState.tasks }
    /// First `URLSessionTask` created on behalf of the `Request`.
    public var firstTask: URLSessionTask? { tasks.first }
    /// Last `URLSessionTask` created on behalf of the `Request`.
    public var lastTask: URLSessionTask? { tasks.last }
    /// Current `URLSessionTask` created on behalf of the `Request`.
    public var task: URLSessionTask? { lastTask }

    // MARK: Metrics

    /// All `URLSessionTaskMetrics` gathered on behalf of the `Request`. Should correspond to the `tasks` created.
    public var allMetrics: [URLSessionTaskMetrics] { mutableState.metrics }
    /// First `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var firstMetrics: URLSessionTaskMetrics? { allMetrics.first }
    /// Last `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var lastMetrics: URLSessionTaskMetrics? { allMetrics.last }
    /// Current `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var metrics: URLSessionTaskMetrics? { lastMetrics }

    // MARK: Retry Count

    /// Number of times the `Request` has been retried.
    public var retryCount: Int { mutableState.retryCount }

    // MARK: Error

    /// `Error` returned from Alamofire internally, from the network request directly, or any validators executed.
    public fileprivate(set) var error: AFError? {
        get { mutableState.error }
        set { mutableState.error = newValue }
    }

    /// Default initializer for the `Request` superclass.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    init(id: UUID = UUID(),
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.id = id
        self.underlyingQueue = underlyingQueue
        self.serializationQueue = serializationQueue
        self.eventMonitor = eventMonitor
        self.interceptor = interceptor
        self.delegate = delegate
    }

    // MARK: - Internal Event API

    // All API must be called from underlyingQueue.

    /// Called when an initial `URLRequest` has been created on behalf of the instance. If a `RequestAdapter` is active,
    /// the `URLRequest` will be adapted before being issued.
    ///
    /// - Parameter request: The `URLRequest` created.
    func didCreateInitialURLRequest(_ request: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { $0.requests.append(request) }

        eventMonitor?.request(self, didCreateInitialURLRequest: request)
    }

    /// Called when initial `URLRequest` creation has failed, typically through a `URLRequestConvertible`.
    ///
    /// - Note: Triggers retry.
    ///
    /// - Parameter error: `AFError` thrown from the failed creation.
    func didFailToCreateURLRequest(with error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = error

        eventMonitor?.request(self, didFailToCreateURLRequestWithError: error)

        callCURLHandlerIfNecessary()

        retryOrFinish(error: error)
    }

    /// Called when a `RequestAdapter` has successfully adapted a `URLRequest`.
    ///
    /// - Parameters:
    ///   - initialRequest: The `URLRequest` that was adapted.
    ///   - adaptedRequest: The `URLRequest` returned by the `RequestAdapter`.
    func didAdaptInitialRequest(_ initialRequest: URLRequest, to adaptedRequest: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { $0.requests.append(adaptedRequest) }

        eventMonitor?.request(self, didAdaptInitialRequest: initialRequest, to: adaptedRequest)
    }

    /// Called when a `RequestAdapter` fails to adapt a `URLRequest`.
    ///
    /// - Note: Triggers retry.
    ///
    /// - Parameters:
    ///   - request: The `URLRequest` the adapter was called with.
    ///   - error:   The `AFError` returned by the `RequestAdapter`.
    func didFailToAdaptURLRequest(_ request: URLRequest, withError error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = error

        eventMonitor?.request(self, didFailToAdaptURLRequest: request, withError: error)

        callCURLHandlerIfNecessary()

        retryOrFinish(error: error)
    }

    /// Final `URLRequest` has been created for the instance.
    ///
    /// - Parameter request: The `URLRequest` created.
    func didCreateURLRequest(_ request: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.read { state in
            state.urlRequestHandler?.queue.async { state.urlRequestHandler?.handler(request) }
        }

        eventMonitor?.request(self, didCreateURLRequest: request)

        callCURLHandlerIfNecessary()
    }

    /// Asynchronously calls any stored `cURLHandler` and then removes it from `mutableState`.
    private func callCURLHandlerIfNecessary() {
        mutableState.write { mutableState in
            guard let cURLHandler = mutableState.cURLHandler else { return }

            cURLHandler.queue.async { cURLHandler.handler(self.cURLDescription()) }

            mutableState.cURLHandler = nil
        }
    }

    /// Called when a `URLSessionTask` is created on behalf of the instance.
    ///
    /// - Parameter task: The `URLSessionTask` created.
    func didCreateTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { state in
            state.tasks.append(task)

            guard let urlSessionTaskHandler = state.urlSessionTaskHandler else { return }

            urlSessionTaskHandler.queue.async { urlSessionTaskHandler.handler(task) }
        }

        eventMonitor?.request(self, didCreateTask: task)
    }

    /// Called when resumption is completed.
    func didResume() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.requestDidResume(self)
    }

    /// Called when a `URLSessionTask` is resumed on behalf of the instance.
    ///
    /// - Parameter task: The `URLSessionTask` resumed.
    func didResumeTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didResumeTask: task)
    }

    /// Called when suspension is completed.
    func didSuspend() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.requestDidSuspend(self)
    }

    /// Called when a `URLSessionTask` is suspended on behalf of the instance.
    ///
    /// - Parameter task: The `URLSessionTask` suspended.
    func didSuspendTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didSuspendTask: task)
    }

    /// Called when cancellation is completed, sets `error` to `AFError.explicitlyCancelled`.
    func didCancel() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { mutableState in
            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
        }

        eventMonitor?.requestDidCancel(self)
    }

    /// Called when a `URLSessionTask` is cancelled on behalf of the instance.
    ///
    /// - Parameter task: The `URLSessionTask` cancelled.
    func didCancelTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didCancelTask: task)
    }

    /// Called when a `URLSessionTaskMetrics` value is gathered on behalf of the instance.
    ///
    /// - Parameter metrics: The `URLSessionTaskMetrics` gathered.
    func didGatherMetrics(_ metrics: URLSessionTaskMetrics) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { $0.metrics.append(metrics) }

        eventMonitor?.request(self, didGatherMetrics: metrics)
    }

    /// Called when a `URLSessionTask` fails before it is finished, typically during certificate pinning.
    ///
    /// - Parameters:
    ///   - task:  The `URLSessionTask` which failed.
    ///   - error: The early failure `AFError`.
    func didFailTask(_ task: URLSessionTask, earlyWithError error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = error

        // Task will still complete, so didCompleteTask(_:with:) will handle retry.
        eventMonitor?.request(self, didFailTask: task, earlyWithError: error)
    }

    /// Called when a `URLSessionTask` completes. All tasks will eventually call this method.
    ///
    /// - Note: Response validation is synchronously triggered in this step.
    ///
    /// - Parameters:
    ///   - task:  The `URLSessionTask` which completed.
    ///   - error: The `AFError` `task` may have completed with. If `error` has already been set on the instance, this
    ///            value is ignored.
    func didCompleteTask(_ task: URLSessionTask, with error: AFError?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = self.error ?? error

        let validators = validators.read { $0 }
        validators.forEach { $0() }

        eventMonitor?.request(self, didCompleteTask: task, with: error)

        retryOrFinish(error: self.error)
    }

    /// Called when the `RequestDelegate` is going to retry this `Request`. Calls `reset()`.
    func prepareForRetry() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { $0.retryCount += 1 }

        reset()

        eventMonitor?.requestIsRetrying(self)
    }

    /// Called to determine whether retry will be triggered for the particular error, or whether the instance should
    /// call `finish()`.
    ///
    /// - Parameter error: The possible `AFError` which may trigger retry.
    func retryOrFinish(error: AFError?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        guard !isCancelled, let error, let delegate else { finish(); return }

        delegate.retryResult(for: self, dueTo: error) { retryResult in
            switch retryResult {
            case .doNotRetry:
                self.finish()
            case let .doNotRetryWithError(retryError):
                self.finish(error: retryError.asAFError(orFailWith: "Received retryError was not already AFError"))
            case .retry, .retryWithDelay:
                delegate.retryRequest(self, withDelay: retryResult.delay)
            }
        }
    }

    /// Finishes this `Request` and starts the response serializers.
    ///
    /// - Parameter error: The possible `Error` with which the instance will finish.
    func finish(error: AFError? = nil) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        guard !mutableState.isFinishing else { return }

        mutableState.isFinishing = true

        if let error { self.error = error }

        // Start response handlers
        processNextResponseSerializer()

        eventMonitor?.requestDidFinish(self)
    }

    /// Appends the response serialization closure to the instance.
    ///
    ///  - Note: This method will also `resume` the instance if `delegate.startImmediately` returns `true`.
    ///
    /// - Parameter closure: The closure containing the response serialization call.
    func appendResponseSerializer(_ closure: @escaping () -> Void) {
        mutableState.write { mutableState in
            mutableState.responseSerializers.append(closure)

            if mutableState.state == .finished {
                mutableState.state = .resumed
            }

            if mutableState.responseSerializerProcessingFinished {
                underlyingQueue.async { self.processNextResponseSerializer() }
            }

            if mutableState.state.canTransitionTo(.resumed) {
                underlyingQueue.async { if self.delegate?.startImmediately == true { self.resume() } }
            }
        }
    }

    /// Returns the next response serializer closure to execute if there's one left.
    ///
    /// - Returns: The next response serialization closure, if there is one.
    func nextResponseSerializer() -> (() -> Void)? {
        var responseSerializer: (() -> Void)?

        mutableState.write { mutableState in
            let responseSerializerIndex = mutableState.responseSerializerCompletions.count

            if responseSerializerIndex < mutableState.responseSerializers.count {
                responseSerializer = mutableState.responseSerializers[responseSerializerIndex]
            }
        }

        return responseSerializer
    }

    /// Processes the next response serializer and calls all completions if response serialization is complete.
    func processNextResponseSerializer() {
        guard let responseSerializer = nextResponseSerializer() else {
            // Execute all response serializer completions and clear them
            var completions: [() -> Void] = []

            mutableState.write { mutableState in
                completions = mutableState.responseSerializerCompletions

                // Clear out all response serializers and response serializer completions in mutable state since the
                // request is complete. It's important to do this prior to calling the completion closures in case
                // the completions call back into the request triggering a re-processing of the response serializers.
                // An example of how this can happen is by calling cancel inside a response completion closure.
                mutableState.responseSerializers.removeAll()
                mutableState.responseSerializerCompletions.removeAll()

                if mutableState.state.canTransitionTo(.finished) {
                    mutableState.state = .finished
                }

                mutableState.responseSerializerProcessingFinished = true
                mutableState.isFinishing = false
            }

            completions.forEach { $0() }

            // Cleanup the request
            cleanup()

            return
        }

        serializationQueue.async { responseSerializer() }
    }

    /// Notifies the `Request` that the response serializer is complete.
    ///
    /// - Parameter completion: The completion handler provided with the response serializer, called when all serializers
    ///                         are complete.
    func responseSerializerDidComplete(completion: @escaping () -> Void) {
        mutableState.write { $0.responseSerializerCompletions.append(completion) }
        processNextResponseSerializer()
    }

    /// Resets all task and response serializer related state for retry.
    func reset() {
        error = nil

        uploadProgress.totalUnitCount = 0
        uploadProgress.completedUnitCount = 0
        downloadProgress.totalUnitCount = 0
        downloadProgress.completedUnitCount = 0

        mutableState.write { state in
            state.isFinishing = false
            state.responseSerializerCompletions = []
        }
    }

    /// Called when updating the upload progress.
    ///
    /// - Parameters:
    ///   - totalBytesSent: Total bytes sent so far.
    ///   - totalBytesExpectedToSend: Total bytes expected to send.
    func updateUploadProgress(totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        uploadProgress.totalUnitCount = totalBytesExpectedToSend
        uploadProgress.completedUnitCount = totalBytesSent

        uploadProgressHandler?.queue.async { self.uploadProgressHandler?.handler(self.uploadProgress) }
    }

    /// Perform a closure on the current `state` while locked.
    ///
    /// - Parameter perform: The closure to perform.
    func withState(perform: (State) -> Void) {
        mutableState.withState(perform: perform)
    }

    // MARK: Task Creation

    /// Called when creating a `URLSessionTask` for this `Request`. Subclasses must override.
    ///
    /// - Parameters:
    ///   - request: `URLRequest` to use to create the `URLSessionTask`.
    ///   - session: `URLSession` which creates the `URLSessionTask`.
    ///
    /// - Returns:   The `URLSessionTask` created.
    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        fatalError("Subclasses must override.")
    }

    // MARK: - Public API

    // These APIs are callable from any queue.

    // MARK: State

    /// Cancels the instance. Once cancelled, a `Request` can no longer be resumed or suspended.
    ///
    /// - Returns: The instance.
    @discardableResult
    public func cancel() -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.cancelled) else { return }

            mutableState.state = .cancelled

            underlyingQueue.async { self.didCancel() }

            guard let task = mutableState.tasks.last, task.state != .completed else {
                underlyingQueue.async { self.finish() }
                return
            }

            // Resume to ensure metrics are gathered.
            task.resume()
            task.cancel()
            underlyingQueue.async { self.didCancelTask(task) }
        }

        return self
    }

    /// Suspends the instance.
    ///
    /// - Returns: The instance.
    @discardableResult
    public func suspend() -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.suspended) else { return }

            mutableState.state = .suspended

            underlyingQueue.async { self.didSuspend() }

            guard let task = mutableState.tasks.last, task.state != .completed else { return }

            task.suspend()
            underlyingQueue.async { self.didSuspendTask(task) }
        }

        return self
    }

    /// Resumes the instance.
    ///
    /// - Returns: The instance.
    @discardableResult
    public func resume() -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.resumed) else { return }

            mutableState.state = .resumed

            underlyingQueue.async { self.didResume() }

            guard let task = mutableState.tasks.last, task.state != .completed else { return }

            task.resume()
            underlyingQueue.async { self.didResumeTask(task) }
        }

        return self
    }

    // MARK: - Closure API

    /// Associates a credential using the provided values with the instance.
    ///
    /// - Parameters:
    ///   - username:    The username.
    ///   - password:    The password.
    ///   - persistence: The `URLCredential.Persistence` for the created `URLCredential`. `.forSession` by default.
    ///
    /// - Returns:       The instance.
    @discardableResult
    public func authenticate(username: String, password: String, persistence: URLCredential.Persistence = .forSession) -> Self {
        let credential = URLCredential(user: username, password: password, persistence: persistence)

        return authenticate(with: credential)
    }

    /// Associates the provided credential with the instance.
    ///
    /// - Parameter credential: The `URLCredential`.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func authenticate(with credential: URLCredential) -> Self {
        mutableState.credential = credential

        return self
    }

    /// Sets a closure to be called periodically during the lifecycle of the instance as data is read from the server.
    ///
    /// - Note: Only the last closure provided is used.
    ///
    /// - Parameters:
    ///   - queue:   The `DispatchQueue` to execute the closure on. `.main` by default.
    ///   - closure: The closure to be executed periodically as data is read from the server.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func downloadProgress(queue: DispatchQueue = .main, closure: @escaping ProgressHandler) -> Self {
        mutableState.downloadProgressHandler = (handler: closure, queue: queue)

        return self
    }

    /// Sets a closure to be called periodically during the lifecycle of the instance as data is sent to the server.
    ///
    /// - Note: Only the last closure provided is used.
    ///
    /// - Parameters:
    ///   - queue:   The `DispatchQueue` to execute the closure on. `.main` by default.
    ///   - closure: The closure to be executed periodically as data is sent to the server.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func uploadProgress(queue: DispatchQueue = .main, closure: @escaping ProgressHandler) -> Self {
        mutableState.uploadProgressHandler = (handler: closure, queue: queue)

        return self
    }

    // MARK: Redirects

    /// Sets the redirect handler for the instance which will be used if a redirect response is encountered.
    ///
    /// - Note: Attempting to set the redirect handler more than once is a logic error and will crash.
    ///
    /// - Parameter handler: The `RedirectHandler`.
    ///
    /// - Returns:           The instance.
    @discardableResult
    public func redirect(using handler: RedirectHandler) -> Self {
        mutableState.write { mutableState in
            precondition(mutableState.redirectHandler == nil, "Redirect handler has already been set.")
            mutableState.redirectHandler = handler
        }

        return self
    }

    // MARK: Cached Responses

    /// Sets the cached response handler for the `Request` which will be used when attempting to cache a response.
    ///
    /// - Note: Attempting to set the cache handler more than once is a logic error and will crash.
    ///
    /// - Parameter handler: The `CachedResponseHandler`.
    ///
    /// - Returns:           The instance.
    @discardableResult
    public func cacheResponse(using handler: CachedResponseHandler) -> Self {
        mutableState.write { mutableState in
            precondition(mutableState.cachedResponseHandler == nil, "Cached response handler has already been set.")
            mutableState.cachedResponseHandler = handler
        }

        return self
    }

    // MARK: - Lifetime APIs

    /// Sets a handler to be called when the cURL description of the request is available.
    ///
    /// - Note: When waiting for a `Request`'s `URLRequest` to be created, only the last `handler` will be called.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called.
    ///   - handler: Closure to be called when the cURL description is available.
    ///
    /// - Returns:           The instance.
    @discardableResult
    public func cURLDescription(on queue: DispatchQueue, calling handler: @escaping (String) -> Void) -> Self {
        mutableState.write { mutableState in
            if mutableState.requests.last != nil {
                queue.async { handler(self.cURLDescription()) }
            } else {
                mutableState.cURLHandler = (queue, handler)
            }
        }

        return self
    }

    /// Sets a handler to be called when the cURL description of the request is available.
    ///
    /// - Note: When waiting for a `Request`'s `URLRequest` to be created, only the last `handler` will be called.
    ///
    /// - Parameter handler: Closure to be called when the cURL description is available. Called on the instance's
    ///                      `underlyingQueue` by default.
    ///
    /// - Returns:           The instance.
    @discardableResult
    public func cURLDescription(calling handler: @escaping (String) -> Void) -> Self {
        cURLDescription(on: underlyingQueue, calling: handler)

        return self
    }

    /// Sets a closure to called whenever Alamofire creates a `URLRequest` for this instance.
    ///
    /// - Note: This closure will be called multiple times if the instance adapts incoming `URLRequest`s or is retried.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called. `.main` by default.
    ///   - handler: Closure to be called when a `URLRequest` is available.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func onURLRequestCreation(on queue: DispatchQueue = .main, perform handler: @escaping (URLRequest) -> Void) -> Self {
        mutableState.write { state in
            if let request = state.requests.last {
                queue.async { handler(request) }
            }

            state.urlRequestHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure to be called whenever the instance creates a `URLSessionTask`.
    ///
    /// - Note: This API should only be used to provide `URLSessionTask`s to existing API, like `NSFileProvider`. It
    ///         **SHOULD NOT** be used to interact with tasks directly, as that may be break Alamofire features.
    ///         Additionally, this closure may be called multiple times if the instance is retried.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called. `.main` by default.
    ///   - handler: Closure to be called when the `URLSessionTask` is available.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func onURLSessionTaskCreation(on queue: DispatchQueue = .main, perform handler: @escaping (URLSessionTask) -> Void) -> Self {
        mutableState.write { state in
            if let task = state.tasks.last {
                queue.async { handler(task) }
            }

            state.urlSessionTaskHandler = (queue, handler)
        }

        return self
    }

    // MARK: Cleanup

    /// Adds a `finishHandler` closure to be called when the request completes.
    ///
    /// - Parameter closure: Closure to be called when the request finishes.
    func onFinish(perform finishHandler: @escaping () -> Void) {
        guard !isFinished else { finishHandler(); return }

        mutableState.write { state in
            state.finishHandlers.append(finishHandler)
        }
    }

    /// Final cleanup step executed when the instance finishes response serialization.
    func cleanup() {
        let handlers = mutableState.finishHandlers
        handlers.forEach { $0() }
        mutableState.write { state in
            state.finishHandlers.removeAll()
        }

        delegate?.cleanup(after: self)
    }
}

extension Request {
    /// Type indicating how a `DataRequest` or `DataStreamRequest` should proceed after receiving an `HTTPURLResponse`.
    public enum ResponseDisposition {
        /// Allow the request to continue normally.
        case allow
        /// Cancel the request, similar to calling `cancel()`.
        case cancel

        var sessionDisposition: URLSession.ResponseDisposition {
            switch self {
            case .allow: return .allow
            case .cancel: return .cancel
            }
        }
    }
}

// MARK: - Protocol Conformances

extension Request: Equatable {
    public static func ==(lhs: Request, rhs: Request) -> Bool {
        lhs.id == rhs.id
    }
}

extension Request: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Request: CustomStringConvertible {
    /// A textual representation of this instance, including the `HTTPMethod` and `URL` if the `URLRequest` has been
    /// created, as well as the response status code, if a response has been received.
    public var description: String {
        guard let request = performedRequests.last ?? lastRequest,
              let url = request.url,
              let method = request.httpMethod else { return "No request created yet." }

        let requestDescription = "\(method) \(url.absoluteString)"

        return response.map { "\(requestDescription) (\($0.statusCode))" } ?? requestDescription
    }
}

extension Request {
    /// cURL representation of the instance.
    ///
    /// - Returns: The cURL equivalent of the instance.
    public func cURLDescription() -> String {
        guard
            let request = lastRequest,
            let url = request.url,
            let host = url.host,
            let method = request.httpMethod else { return "$ curl command could not be created" }

        var components = ["$ curl -v"]

        components.append("-X \(method)")

        if let credentialStorage = delegate?.sessionConfiguration.urlCredentialStorage {
            let protectionSpace = URLProtectionSpace(host: host,
                                                     port: url.port ?? 0,
                                                     protocol: url.scheme,
                                                     realm: host,
                                                     authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

            if let credentials = credentialStorage.credentials(for: protectionSpace)?.values {
                for credential in credentials {
                    guard let user = credential.user, let password = credential.password else { continue }
                    components.append("-u \(user):\(password)")
                }
            } else {
                if let credential, let user = credential.user, let password = credential.password {
                    components.append("-u \(user):\(password)")
                }
            }
        }

        if let configuration = delegate?.sessionConfiguration, configuration.httpShouldSetCookies {
            if
                let cookieStorage = configuration.httpCookieStorage,
                let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty {
                let allCookies = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: ";")

                components.append("-b \"\(allCookies)\"")
            }
        }

        var headers = HTTPHeaders()

        if let sessionHeaders = delegate?.sessionConfiguration.headers {
            for header in sessionHeaders where header.name != "Cookie" {
                headers[header.name] = header.value
            }
        }

        for header in request.headers where header.name != "Cookie" {
            headers[header.name] = header.value
        }

        for header in headers {
            let escapedValue = header.value.replacingOccurrences(of: "\"", with: "\\\"")
            components.append("-H \"\(header.name): \(escapedValue)\"")
        }

        if let httpBodyData = request.httpBody {
            let httpBody = String(decoding: httpBodyData, as: UTF8.self)
            var escapedBody = httpBody.replacingOccurrences(of: "\\\"", with: "\\\\\"")
            escapedBody = escapedBody.replacingOccurrences(of: "\"", with: "\\\"")

            components.append("-d \"\(escapedBody)\"")
        }

        components.append("\"\(url.absoluteString)\"")

        return components.joined(separator: " \\\n\t")
    }
}

/// Protocol abstraction for `Request`'s communication back to the `SessionDelegate`.
public protocol RequestDelegate: AnyObject {
    /// `URLSessionConfiguration` used to create the underlying `URLSessionTask`s.
    var sessionConfiguration: URLSessionConfiguration { get }

    /// Determines whether the `Request` should automatically call `resume()` when adding the first response handler.
    var startImmediately: Bool { get }

    /// Notifies the delegate the `Request` has reached a point where it needs cleanup.
    ///
    /// - Parameter request: The `Request` to cleanup after.
    func cleanup(after request: Request)

    /// Asynchronously ask the delegate whether a `Request` will be retried.
    ///
    /// - Parameters:
    ///   - request:    `Request` which failed.
    ///   - error:      `Error` which produced the failure.
    ///   - completion: Closure taking the `RetryResult` for evaluation.
    func retryResult(for request: Request, dueTo error: AFError, completion: @escaping (RetryResult) -> Void)

    /// Asynchronously retry the `Request`.
    ///
    /// - Parameters:
    ///   - request:   `Request` which will be retried.
    ///   - timeDelay: `TimeInterval` after which the retry will be triggered.
    func retryRequest(_ request: Request, withDelay timeDelay: TimeInterval?)
}

// MARK: - Subclasses

// MARK: - DataRequest

/// `Request` subclass which handles in-memory `Data` download using `URLSessionDataTask`.
public class DataRequest: Request {
    /// `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    public let convertible: URLRequestConvertible
    /// `Data` read from the server so far.
    public var data: Data? { dataMutableState.data }

    private struct DataMutableState {
        var data: Data?
        var httpResponseHandler: (queue: DispatchQueue,
                                  handler: (_ response: HTTPURLResponse,
                                            _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void)?
    }

    private let dataMutableState = Protected(DataMutableState())

    /// Creates a `DataRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - convertible:        `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    init(id: UUID = UUID(),
         convertible: URLRequestConvertible,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.convertible = convertible

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func reset() {
        super.reset()

        dataMutableState.write { mutableState in
            mutableState.data = nil
        }
    }

    /// Called when `Data` is received by this instance.
    ///
    /// - Note: Also calls `updateDownloadProgress`.
    ///
    /// - Parameter data: The `Data` received.
    func didReceive(data: Data) {
        dataMutableState.write { mutableState in
            if mutableState.data == nil {
                mutableState.data = data
            } else {
                mutableState.data?.append(data)
            }
        }

        updateDownloadProgress()
    }

    func didReceiveResponse(_ response: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        dataMutableState.read { dataMutableState in
            guard let httpResponseHandler = dataMutableState.httpResponseHandler else {
                underlyingQueue.async { completionHandler(.allow) }
                return
            }

            httpResponseHandler.queue.async {
                httpResponseHandler.handler(response) { disposition in
                    if disposition == .cancel {
                        self.mutableState.write { mutableState in
                            mutableState.state = .cancelled
                            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
                        }
                    }

                    self.underlyingQueue.async {
                        completionHandler(disposition.sessionDisposition)
                    }
                }
            }
        }
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let copiedRequest = request
        return session.dataTask(with: copiedRequest)
    }

    /// Called to update the `downloadProgress` of the instance.
    func updateDownloadProgress() {
        let totalBytesReceived = Int64(data?.count ?? 0)
        let totalBytesExpected = task?.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown

        downloadProgress.totalUnitCount = totalBytesExpected
        downloadProgress.completedUnitCount = totalBytesReceived

        downloadProgressHandler?.queue.async { self.downloadProgressHandler?.handler(self.downloadProgress) }
    }

    /// Validates the request, using the specified closure.
    ///
    /// - Note: If validation fails, subsequent calls to response handlers will have an associated error.
    ///
    /// - Parameter validation: `Validation` closure used to validate the response.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response, data)

            if case let .failure(error) = result { self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error))) }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  data: data,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse` and providing a completion
    /// handler to return a `ResponseDisposition` value.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`. The `completionHandler` provided
    ///              MUST be called, otherwise the request will never complete.
    ///
    /// - Returns:   The instance.
    @_disfavoredOverload
    @discardableResult
    public func onHTTPResponse(
        on queue: DispatchQueue = .main,
        perform handler: @escaping (_ response: HTTPURLResponse,
                                    _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void
    ) -> Self {
        dataMutableState.write { mutableState in
            mutableState.httpResponseHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse`.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func onHTTPResponse(on queue: DispatchQueue = .main,
                               perform handler: @escaping (HTTPURLResponse) -> Void) -> Self {
        onHTTPResponse(on: queue) { response, completionHandler in
            handler(response)
            completionHandler(.allow)
        }

        return self
    }
}

// MARK: - DataStreamRequest

/// `Request` subclass which streams HTTP response `Data` through a `Handler` closure.
public final class DataStreamRequest: Request {
    /// Closure type handling `DataStreamRequest.Stream` values.
    public typealias Handler<Success, Failure: Error> = (Stream<Success, Failure>) throws -> Void

    /// Type encapsulating an `Event` as it flows through the stream, as well as a `CancellationToken` which can be used
    /// to stop the stream at any time.
    public struct Stream<Success, Failure: Error> {
        /// Latest `Event` from the stream.
        public let event: Event<Success, Failure>
        /// Token used to cancel the stream.
        public let token: CancellationToken

        /// Cancel the ongoing stream by canceling the underlying `DataStreamRequest`.
        public func cancel() {
            token.cancel()
        }
    }

    /// Type representing an event flowing through the stream. Contains either the `Result` of processing streamed
    /// `Data` or the completion of the stream.
    public enum Event<Success, Failure: Error> {
        /// Output produced every time the instance receives additional `Data`. The associated value contains the
        /// `Result` of processing the incoming `Data`.
        case stream(Result<Success, Failure>)
        /// Output produced when the instance has completed, whether due to stream end, cancellation, or an error.
        /// Associated `Completion` value contains the final state.
        case complete(Completion)
    }

    /// Value containing the state of a `DataStreamRequest` when the stream was completed.
    public struct Completion {
        /// Last `URLRequest` issued by the instance.
        public let request: URLRequest?
        /// Last `HTTPURLResponse` received by the instance.
        public let response: HTTPURLResponse?
        /// Last `URLSessionTaskMetrics` produced for the instance.
        public let metrics: URLSessionTaskMetrics?
        /// `AFError` produced for the instance, if any.
        public let error: AFError?
    }

    /// Type used to cancel an ongoing stream.
    public struct CancellationToken {
        weak var request: DataStreamRequest?

        init(_ request: DataStreamRequest) {
            self.request = request
        }

        /// Cancel the ongoing stream by canceling the underlying `DataStreamRequest`.
        public func cancel() {
            request?.cancel()
        }
    }

    /// `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    public let convertible: URLRequestConvertible
    /// Whether or not the instance will be cancelled if stream parsing encounters an error.
    public let automaticallyCancelOnStreamError: Bool

    /// Internal mutable state specific to this type.
    struct StreamMutableState {
        /// `OutputStream` bound to the `InputStream` produced by `asInputStream`, if it has been called.
        var outputStream: OutputStream?
        /// Stream closures called as `Data` is received.
        var streams: [(_ data: Data) -> Void] = []
        /// Number of currently executing streams. Used to ensure completions are only fired after all streams are
        /// enqueued.
        var numberOfExecutingStreams = 0
        /// Completion calls enqueued while streams are still executing.
        var enqueuedCompletionEvents: [() -> Void] = []
        /// Handler for any `HTTPURLResponse`s received.
        var httpResponseHandler: (queue: DispatchQueue,
                                  handler: (_ response: HTTPURLResponse,
                                            _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void)?
    }

    let streamMutableState = Protected(StreamMutableState())

    /// Creates a `DataStreamRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                               `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()`
    ///                                        by default.
    ///   - convertible:                      `URLRequestConvertible` value used to create `URLRequest`s for this
    ///                                        instance.
    ///   - automaticallyCancelOnStreamError: `Bool` indicating whether the instance will be cancelled when an `Error`
    ///                                       is thrown while serializing stream `Data`.
    ///   - underlyingQueue:                  `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue:               `DispatchQueue` on which all serialization work is performed. By default
    ///                                       targets
    ///                                       `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:                     `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:                      `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:                         `RequestDelegate` that provides an interface to actions not performed by
    ///                                       the `Request`.
    init(id: UUID = UUID(),
         convertible: URLRequestConvertible,
         automaticallyCancelOnStreamError: Bool,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.convertible = convertible
        self.automaticallyCancelOnStreamError = automaticallyCancelOnStreamError

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let copiedRequest = request
        return session.dataTask(with: copiedRequest)
    }

    override func finish(error: AFError? = nil) {
        streamMutableState.write { state in
            state.outputStream?.close()
        }

        super.finish(error: error)
    }

    func didReceive(data: Data) {
        streamMutableState.write { state in
            #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
            if let stream = state.outputStream {
                underlyingQueue.async {
                    var bytes = Array(data)
                    stream.write(&bytes, maxLength: bytes.count)
                }
            }
            #endif
            state.numberOfExecutingStreams += state.streams.count
            let localState = state
            underlyingQueue.async { localState.streams.forEach { $0(data) } }
        }
    }

    func didReceiveResponse(_ response: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamMutableState.read { dataMutableState in
            guard let httpResponseHandler = dataMutableState.httpResponseHandler else {
                underlyingQueue.async { completionHandler(.allow) }
                return
            }

            httpResponseHandler.queue.async {
                httpResponseHandler.handler(response) { disposition in
                    if disposition == .cancel {
                        self.mutableState.write { mutableState in
                            mutableState.state = .cancelled
                            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
                        }
                    }

                    self.underlyingQueue.async {
                        completionHandler(disposition.sessionDisposition)
                    }
                }
            }
        }
    }

    /// Validates the `URLRequest` and `HTTPURLResponse` received for the instance using the provided `Validation` closure.
    ///
    /// - Parameter validation: `Validation` closure used to validate the request and response.
    ///
    /// - Returns:              The `DataStreamRequest`.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response)

            if case let .failure(error) = result {
                self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error)))
            }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }

    #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
    /// Produces an `InputStream` that receives the `Data` received by the instance.
    ///
    /// - Note: The `InputStream` produced by this method must have `open()` called before being able to read `Data`.
    ///         Additionally, this method will automatically call `resume()` on the instance, regardless of whether or
    ///         not the creating session has `startRequestsImmediately` set to `true`.
    ///
    /// - Parameter bufferSize: Size, in bytes, of the buffer between the `OutputStream` and `InputStream`.
    ///
    /// - Returns:              The `InputStream` bound to the internal `OutboundStream`.
    public func asInputStream(bufferSize: Int = 1024) -> InputStream? {
        defer { resume() }

        var inputStream: InputStream?
        streamMutableState.write { state in
            Foundation.Stream.getBoundStreams(withBufferSize: bufferSize,
                                              inputStream: &inputStream,
                                              outputStream: &state.outputStream)
            state.outputStream?.open()
        }

        return inputStream
    }
    #endif

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse` and providing a completion
    /// handler to return a `ResponseDisposition` value.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`. The `completionHandler` provided
    ///              MUST be called, otherwise the request will never complete.
    ///
    /// - Returns:   The instance.
    @_disfavoredOverload
    @discardableResult
    public func onHTTPResponse(
        on queue: DispatchQueue = .main,
        perform handler: @escaping (_ response: HTTPURLResponse,
                                    _ completionHandler: @escaping (ResponseDisposition) -> Void) -> Void
    ) -> Self {
        streamMutableState.write { mutableState in
            mutableState.httpResponseHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse`.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`.
    ///
    /// - Returns:   The instance.
    @discardableResult
    public func onHTTPResponse(on queue: DispatchQueue = .main,
                               perform handler: @escaping (HTTPURLResponse) -> Void) -> Self {
        onHTTPResponse(on: queue) { response, completionHandler in
            handler(response)
            completionHandler(.allow)
        }

        return self
    }

    func capturingError(from closure: () throws -> Void) {
        do {
            try closure()
        } catch {
            self.error = error.asAFError(or: .responseSerializationFailed(reason: .customSerializationFailed(error: error)))
            cancel()
        }
    }

    func appendStreamCompletion<Success, Failure>(on queue: DispatchQueue,
                                                  stream: @escaping Handler<Success, Failure>) {
        appendResponseSerializer {
            self.underlyingQueue.async {
                self.responseSerializerDidComplete {
                    self.streamMutableState.write { state in
                        guard state.numberOfExecutingStreams == 0 else {
                            state.enqueuedCompletionEvents.append {
                                self.enqueueCompletion(on: queue, stream: stream)
                            }

                            return
                        }

                        self.enqueueCompletion(on: queue, stream: stream)
                    }
                }
            }
        }
    }

    func enqueueCompletion<Success, Failure>(on queue: DispatchQueue,
                                             stream: @escaping Handler<Success, Failure>) {
        queue.async {
            do {
                let completion = Completion(request: self.request,
                                            response: self.response,
                                            metrics: self.metrics,
                                            error: self.error)
                try stream(.init(event: .complete(completion), token: .init(self)))
            } catch {
                // Ignore error, as errors on Completion can't be handled anyway.
            }
        }
    }
}

extension DataStreamRequest.Stream {
    /// Incoming `Result` values from `Event.stream`.
    public var result: Result<Success, Failure>? {
        guard case let .stream(result) = event else { return nil }

        return result
    }

    /// `Success` value of the instance, if any.
    public var value: Success? {
        guard case let .success(value) = result else { return nil }

        return value
    }

    /// `Failure` value of the instance, if any.
    public var error: Failure? {
        guard case let .failure(error) = result else { return nil }

        return error
    }

    /// `Completion` value of the instance, if any.
    public var completion: DataStreamRequest.Completion? {
        guard case let .complete(completion) = event else { return nil }

        return completion
    }
}

// MARK: - WebSocketRequest

#if canImport(Darwin) && !canImport(FoundationNetworking) // Only Apple platforms support URLSessionWebSocketTask.

/// `Request` subclass which manages a WebSocket connection using `URLSessionWebSocketTask`.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@_spi(WebSocket) public final class WebSocketRequest: Request {
    enum IncomingEvent {
        case connected(protocol: String?)
        case receivedMessage(URLSessionWebSocketTask.Message)
        case disconnected(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
        case completed(Completion)
    }

    public struct Event<Success, Failure: Error> {
        public enum Kind {
            case connected(protocol: String?)
            case receivedMessage(Success)
            case serializerFailed(Failure)
            // Only received if the server disconnects or we cancel with code, not if we do a simple cancel or error.
            case disconnected(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
            case completed(Completion)
        }

        weak var socket: WebSocketRequest?

        public let kind: Kind
        public var message: Success? {
            guard case let .receivedMessage(message) = kind else { return nil }

            return message
        }

        init(socket: WebSocketRequest, kind: Kind) {
            self.socket = socket
            self.kind = kind
        }

        public func close(sending closeCode: URLSessionWebSocketTask.CloseCode, reason: Data? = nil) {
            socket?.close(sending: closeCode, reason: reason)
        }

        public func cancel() {
            socket?.cancel()
        }

        public func sendPing(respondingOn queue: DispatchQueue = .main, onResponse: @escaping (PingResponse) -> Void) {
            socket?.sendPing(respondingOn: queue, onResponse: onResponse)
        }
    }

    public struct Completion {
        /// Last `URLRequest` issued by the instance.
        public let request: URLRequest?
        /// Last `HTTPURLResponse` received by the instance.
        public let response: HTTPURLResponse?
        /// Last `URLSessionTaskMetrics` produced for the instance.
        public let metrics: URLSessionTaskMetrics?
        /// `AFError` produced for the instance, if any.
        public let error: AFError?
    }

    public struct Configuration {
        public static var `default`: Self { Self() }

        public static func `protocol`(_ protocol: String) -> Self {
            Self(protocol: `protocol`)
        }

        public static func maximumMessageSize(_ maximumMessageSize: Int) -> Self {
            Self(maximumMessageSize: maximumMessageSize)
        }

        public static func pingInterval(_ pingInterval: TimeInterval) -> Self {
            Self(pingInterval: pingInterval)
        }

        public let `protocol`: String?
        public let maximumMessageSize: Int
        public let pingInterval: TimeInterval?

        init(protocol: String? = nil, maximumMessageSize: Int = 1_048_576, pingInterval: TimeInterval? = nil) {
            self.protocol = `protocol`
            self.maximumMessageSize = maximumMessageSize
            self.pingInterval = pingInterval
        }
    }

    /// Response to a sent ping.
    public enum PingResponse {
        public struct Pong {
            let start: Date
            let end: Date
            let latency: TimeInterval
        }

        /// Received a pong with the associated state.
        case pong(Pong)
        /// Received an error.
        case error(Error)
        /// Did not send the ping, the request is cancelled or suspended.
        case unsent
    }

    struct SocketMutableState {
        var enqueuedSends: [(message: URLSessionWebSocketTask.Message,
                             queue: DispatchQueue,
                             completionHandler: (Result<Void, Error>) -> Void)] = []
        var handlers: [(queue: DispatchQueue, handler: (_ event: IncomingEvent) -> Void)] = []
        var pingTimerItem: DispatchWorkItem?
    }

    let socketMutableState = Protected(SocketMutableState())

    var socket: URLSessionWebSocketTask? {
        task as? URLSessionWebSocketTask
    }

    public let convertible: URLRequestConvertible
    public let configuration: Configuration

    init(id: UUID = UUID(),
         convertible: URLRequestConvertible,
         configuration: Configuration,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate) {
        self.convertible = convertible
        self.configuration = configuration

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        var copiedRequest = request
        let task: URLSessionWebSocketTask
        if let `protocol` = configuration.protocol {
            copiedRequest.headers.update(.websocketProtocol(`protocol`))
            task = session.webSocketTask(with: copiedRequest)
        } else {
            task = session.webSocketTask(with: copiedRequest)
        }
        task.maximumMessageSize = configuration.maximumMessageSize

        return task
    }

    override func didCreateTask(_ task: URLSessionTask) {
        super.didCreateTask(task)

        guard let webSocketTask = task as? URLSessionWebSocketTask else {
            fatalError("Invalid task of type \(task.self) created for WebSocketRequest.")
        }
        // TODO: What about the any old tasks? Reset their receive?
        listen(to: webSocketTask)

        // Empty pending messages.
        socketMutableState.write { state in
            guard !state.enqueuedSends.isEmpty else { return }

            let sends = state.enqueuedSends
            self.underlyingQueue.async {
                for send in sends {
                    webSocketTask.send(send.message) { error in
                        send.queue.async {
                            send.completionHandler(Result(value: (), error: error))
                        }
                    }
                }
            }

            state.enqueuedSends = []
        }
    }

    func didClose() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { mutableState in
            // Check whether error is cancellation or other websocket closing error.
            // If so, remove it.
            // Otherwise keep it.
            if case let .sessionTaskFailed(error) = mutableState.error, (error as? URLError)?.code == .cancelled {
                mutableState.error = nil
            }
        }

        // TODO: Still issue this event?
        eventMonitor?.requestDidCancel(self)
    }

    @discardableResult
    public func close(sending closeCode: URLSessionWebSocketTask.CloseCode, reason: Data? = nil) -> Self {
        cancelAutomaticPing()

        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.cancelled) else { return }

            mutableState.state = .cancelled

            underlyingQueue.async { self.didClose() }

            guard let task = mutableState.tasks.last, task.state != .completed else {
                underlyingQueue.async { self.finish() }
                return
            }

            // Resume to ensure metrics are gathered.
            task.resume()
            // Cast from state directly, not the property, otherwise the lock is recursive.
            (mutableState.tasks.last as? URLSessionWebSocketTask)?.cancel(with: closeCode, reason: reason)
            underlyingQueue.async { self.didCancelTask(task) }
        }

        return self
    }

    @discardableResult
    override public func cancel() -> Self {
        cancelAutomaticPing()

        return super.cancel()
    }

    func didConnect(protocol: String?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        socketMutableState.read { state in
            // TODO: Capture HTTPURLResponse here too?
            for handler in state.handlers {
                // Saved handler calls out to serializationQueue immediately, then to handler's queue.
                handler.handler(.connected(protocol: `protocol`))
            }
        }

        if let pingInterval = configuration.pingInterval {
            startAutomaticPing(every: pingInterval)
        }
    }

    public func sendPing(respondingOn queue: DispatchQueue = .main, onResponse: @escaping (PingResponse) -> Void) {
        guard isResumed else {
            queue.async { onResponse(.unsent) }
            return
        }

        let start = Date()
        let startTimestamp = ProcessInfo.processInfo.systemUptime
        socket?.sendPing { error in
            // Calls back on delegate queue / rootQueue / underlyingQueue
            if let error {
                queue.async {
                    onResponse(.error(error))
                }
                // TODO: What to do with failed ping? Configure for failure, auto retry, or stop pinging?
            } else {
                let end = Date()
                let endTimestamp = ProcessInfo.processInfo.systemUptime
                let pong = PingResponse.Pong(start: start, end: end, latency: endTimestamp - startTimestamp)

                queue.async {
                    onResponse(.pong(pong))
                }
            }
        }
    }

    func startAutomaticPing(every pingInterval: TimeInterval) {
        socketMutableState.write { mutableState in
            guard isResumed else {
                // Defer out of lock.
                defer { cancelAutomaticPing() }
                return
            }

            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isResumed else { return }

                self.sendPing(respondingOn: self.underlyingQueue) { response in
                    guard case .pong = response else { return }

                    self.startAutomaticPing(every: pingInterval)
                }
            }

            mutableState.pingTimerItem = item
            underlyingQueue.asyncAfter(deadline: .now() + pingInterval, execute: item)
        }
    }

    #if swift(>=5.8)
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func startAutomaticPing(every duration: Duration) {
        let interval = TimeInterval(duration.components.seconds) + (Double(duration.components.attoseconds) / 1e18)
        startAutomaticPing(every: interval)
    }
    #endif

    func cancelAutomaticPing() {
        socketMutableState.write { mutableState in
            mutableState.pingTimerItem?.cancel()
            mutableState.pingTimerItem = nil
        }
    }

    func didDisconnect(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        cancelAutomaticPing()
        socketMutableState.read { state in
            for handler in state.handlers {
                // Saved handler calls out to serializationQueue immediately, then to handler's queue.
                handler.handler(.disconnected(closeCode: closeCode, reason: reason))
            }
        }
    }

    private func listen(to task: URLSessionWebSocketTask) {
        // TODO: Do we care about the cycle while receiving?
        task.receive { result in
            switch result {
            case let .success(message):
                self.socketMutableState.read { state in
                    for handler in state.handlers {
                        // Saved handler calls out to serializationQueue immediately, then to handler's queue.
                        handler.handler(.receivedMessage(message))
                    }
                }

                self.listen(to: task)
            case .failure:
                // It doesn't seem like any relevant errors are received here, just incorrect garbage, like errors when
                // the socket disconnects.
                break
            }
        }
    }

    @discardableResult
    public func streamSerializer<Serializer>(
        _ serializer: Serializer,
        on queue: DispatchQueue = .main,
        handler: @escaping (_ event: Event<Serializer.Output, Serializer.Failure>) -> Void
    ) -> Self where Serializer: WebSocketMessageSerializer, Serializer.Failure == Error {
        forIncomingEvent(on: queue) { incomingEvent in
            let event: Event<Serializer.Output, Serializer.Failure>
            switch incomingEvent {
            case let .connected(`protocol`):
                event = .init(socket: self, kind: .connected(protocol: `protocol`))
            case let .receivedMessage(message):
                do {
                    let serializedMessage = try serializer.decode(message)
                    event = .init(socket: self, kind: .receivedMessage(serializedMessage))
                } catch {
                    event = .init(socket: self, kind: .serializerFailed(error))
                }
            case let .disconnected(closeCode, reason):
                event = .init(socket: self, kind: .disconnected(closeCode: closeCode, reason: reason))
            case let .completed(completion):
                event = .init(socket: self, kind: .completed(completion))
            }

            queue.async { handler(event) }
        }
    }

    @discardableResult
    public func streamDecodableEvents<Value>(
        _ type: Value.Type = Value.self,
        on queue: DispatchQueue = .main,
        using decoder: DataDecoder = JSONDecoder(),
        handler: @escaping (_ event: Event<Value, Error>) -> Void
    ) -> Self where Value: Decodable {
        streamSerializer(DecodableWebSocketMessageDecoder<Value>(decoder: decoder), on: queue, handler: handler)
    }

    @discardableResult
    public func streamDecodable<Value>(
        _ type: Value.Type = Value.self,
        on queue: DispatchQueue = .main,
        using decoder: DataDecoder = JSONDecoder(),
        handler: @escaping (_ value: Value) -> Void
    ) -> Self where Value: Decodable {
        streamDecodableEvents(Value.self, on: queue) { event in
            event.message.map(handler)
        }
    }

    @discardableResult
    public func streamMessageEvents(
        on queue: DispatchQueue = .main,
        handler: @escaping (_ event: Event<URLSessionWebSocketTask.Message, Never>) -> Void
    ) -> Self {
        forIncomingEvent(on: queue) { incomingEvent in
            let event: Event<URLSessionWebSocketTask.Message, Never>
            switch incomingEvent {
            case let .connected(`protocol`):
                event = .init(socket: self, kind: .connected(protocol: `protocol`))
            case let .receivedMessage(message):
                event = .init(socket: self, kind: .receivedMessage(message))
            case let .disconnected(closeCode, reason):
                event = .init(socket: self, kind: .disconnected(closeCode: closeCode, reason: reason))
            case let .completed(completion):
                event = .init(socket: self, kind: .completed(completion))
            }

            queue.async { handler(event) }
        }
    }

    @discardableResult
    public func streamMessages(
        on queue: DispatchQueue = .main,
        handler: @escaping (_ message: URLSessionWebSocketTask.Message) -> Void
    ) -> Self {
        streamMessageEvents(on: queue) { event in
            event.message.map(handler)
        }
    }

    func forIncomingEvent(on queue: DispatchQueue, handler: @escaping (IncomingEvent) -> Void) -> Self {
        socketMutableState.write { state in
            state.handlers.append((queue: queue, handler: { incomingEvent in
                self.serializationQueue.async {
                    handler(incomingEvent)
                }
            }))
        }

        appendResponseSerializer {
            self.responseSerializerDidComplete {
                self.serializationQueue.async {
                    handler(.completed(.init(request: self.request,
                                             response: self.response,
                                             metrics: self.metrics,
                                             error: self.error)))
                }
            }
        }

        return self
    }

    public func send(_ message: URLSessionWebSocketTask.Message,
                     queue: DispatchQueue = .main,
                     completionHandler: @escaping (Result<Void, Error>) -> Void) {
        guard !(isCancelled || isFinished) else { return }

        guard let socket else {
            // URLSessionWebSocketTask note created yet, enqueue the send.
            socketMutableState.write { mutableState in
                mutableState.enqueuedSends.append((message, queue, completionHandler))
            }

            return
        }

        socket.send(message) { error in
            queue.async {
                completionHandler(Result(value: (), error: error))
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol WebSocketMessageSerializer<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error = Error

    func decode(_ message: URLSessionWebSocketTask.Message) throws -> Output
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension WebSocketMessageSerializer {
    public static func json<Value>(
        decoding _: Value.Type = Value.self,
        using decoder: JSONDecoder = JSONDecoder()
    ) -> DecodableWebSocketMessageDecoder<Value> where Self == DecodableWebSocketMessageDecoder<Value> {
        Self(decoder: decoder)
    }

    static var passthrough: PassthroughWebSocketMessageDecoder {
        PassthroughWebSocketMessageDecoder()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
struct PassthroughWebSocketMessageDecoder: WebSocketMessageSerializer {
    public typealias Failure = Never

    public func decode(_ message: URLSessionWebSocketTask.Message) -> URLSessionWebSocketTask.Message {
        message
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct DecodableWebSocketMessageDecoder<Value: Decodable>: WebSocketMessageSerializer {
    public enum Error: Swift.Error {
        case decoding(Swift.Error)
        case unknownMessage(description: String)
    }

    public let decoder: DataDecoder

    public init(decoder: DataDecoder) {
        self.decoder = decoder
    }

    public func decode(_ message: URLSessionWebSocketTask.Message) throws -> Value {
        let data: Data
        switch message {
        case let .data(messageData):
            data = messageData
        case let .string(string):
            data = Data(string.utf8)
        @unknown default:
            throw Error.unknownMessage(description: String(describing: message))
        }

        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw Error.decoding(error)
        }
    }
}

#endif

// MARK: - DownloadRequest

/// `Request` subclass which downloads `Data` to a file on disk using `URLSessionDownloadTask`.
public class DownloadRequest: Request {
    /// A set of options to be executed prior to moving a downloaded file from the temporary `URL` to the destination
    /// `URL`.
    public struct Options: OptionSet {
        /// Specifies that intermediate directories for the destination URL should be created.
        public static let createIntermediateDirectories = Options(rawValue: 1 << 0)
        /// Specifies that any previous file at the destination `URL` should be removed.
        public static let removePreviousFile = Options(rawValue: 1 << 1)

        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    // MARK: Destination

    /// A closure executed once a `DownloadRequest` has successfully completed in order to determine where to move the
    /// temporary file written to during the download process. The closure takes two arguments: the temporary file URL
    /// and the `HTTPURLResponse`, and returns two values: the file URL where the temporary file should be moved and
    /// the options defining how the file should be moved.
    ///
    /// - Note: Downloads from a local `file://` `URL`s do not use the `Destination` closure, as those downloads do not
    ///         return an `HTTPURLResponse`. Instead the file is merely moved within the temporary directory.
    public typealias Destination = (_ temporaryURL: URL,
                                    _ response: HTTPURLResponse) -> (destinationURL: URL, options: Options)

    /// Creates a download file destination closure which uses the default file manager to move the temporary file to a
    /// file URL in the first available directory with the specified search path directory and search path domain mask.
    ///
    /// - Parameters:
    ///   - directory: The search path directory. `.documentDirectory` by default.
    ///   - domain:    The search path domain mask. `.userDomainMask` by default.
    ///   - options:   `DownloadRequest.Options` used when moving the downloaded file to its destination. None by
    ///                default.
    /// - Returns: The `Destination` closure.
    public class func suggestedDownloadDestination(for directory: FileManager.SearchPathDirectory = .documentDirectory,
                                                   in domain: FileManager.SearchPathDomainMask = .userDomainMask,
                                                   options: Options = []) -> Destination {
        { temporaryURL, response in
            let directoryURLs = FileManager.default.urls(for: directory, in: domain)
            let url = directoryURLs.first?.appendingPathComponent(response.suggestedFilename!) ?? temporaryURL

            return (url, options)
        }
    }

    /// Default `Destination` used by Alamofire to ensure all downloads persist. This `Destination` prepends
    /// `Alamofire_` to the automatically generated download name and moves it within the temporary directory. Files
    /// with this destination must be additionally moved if they should survive the system reclamation of temporary
    /// space.
    static let defaultDestination: Destination = { url, _ in
        (defaultDestinationURL(url), [])
    }

    /// Default `URL` creation closure. Creates a `URL` in the temporary directory with `Alamofire_` prepended to the
    /// provided file name.
    static let defaultDestinationURL: (URL) -> URL = { url in
        let filename = "Alamofire_\(url.lastPathComponent)"
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename)

        return destination
    }

    // MARK: Downloadable

    /// Type describing the source used to create the underlying `URLSessionDownloadTask`.
    public enum Downloadable {
        /// Download should be started from the `URLRequest` produced by the associated `URLRequestConvertible` value.
        case request(URLRequestConvertible)
        /// Download should be started from the associated resume `Data` value.
        case resumeData(Data)
    }

    // MARK: Mutable State

    /// Type containing all mutable state for `DownloadRequest` instances.
    private struct DownloadRequestMutableState {
        /// Possible resume `Data` produced when cancelling the instance.
        var resumeData: Data?
        /// `URL` to which `Data` is being downloaded.
        var fileURL: URL?
    }

    /// Protected mutable state specific to `DownloadRequest`.
    private let mutableDownloadState = Protected(DownloadRequestMutableState())

    /// If the download is resumable and is eventually cancelled or fails, this value may be used to resume the download
    /// using the `download(resumingWith data:)` API.
    ///
    /// - Note: For more information about `resumeData`, see [Apple's documentation](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/1411634-cancel).
    public var resumeData: Data? {
        #if !canImport(FoundationNetworking) // If we not using swift-corelibs-foundation.
        return mutableDownloadState.resumeData ?? error?.downloadResumeData
        #else
        return mutableDownloadState.resumeData
        #endif
    }

    /// If the download is successful, the `URL` where the file was downloaded.
    public var fileURL: URL? { mutableDownloadState.fileURL }

    // MARK: Initial State

    /// `Downloadable` value used for this instance.
    public let downloadable: Downloadable
    /// The `Destination` to which the downloaded file is moved.
    let destination: Destination

    /// Creates a `DownloadRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - downloadable:       `Downloadable` value used to create `URLSessionDownloadTasks` for the instance.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`
    ///   - destination:        `Destination` closure used to move the downloaded file to its final location.
    init(id: UUID = UUID(),
         downloadable: Downloadable,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         delegate: RequestDelegate,
         destination: @escaping Destination) {
        self.downloadable = downloadable
        self.destination = destination

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    override func reset() {
        super.reset()

        mutableDownloadState.write {
            $0.resumeData = nil
            $0.fileURL = nil
        }
    }

    /// Called when a download has finished.
    ///
    /// - Parameters:
    ///   - task:   `URLSessionTask` that finished the download.
    ///   - result: `Result` of the automatic move to `destination`.
    func didFinishDownloading(using task: URLSessionTask, with result: Result<URL, AFError>) {
        eventMonitor?.request(self, didFinishDownloadingUsing: task, with: result)

        switch result {
        case let .success(url): mutableDownloadState.fileURL = url
        case let .failure(error): self.error = error
        }
    }

    /// Updates the `downloadProgress` using the provided values.
    ///
    /// - Parameters:
    ///   - bytesWritten:              Total bytes written so far.
    ///   - totalBytesExpectedToWrite: Total bytes expected to write.
    func updateDownloadProgress(bytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloadProgress.totalUnitCount = totalBytesExpectedToWrite
        downloadProgress.completedUnitCount += bytesWritten

        downloadProgressHandler?.queue.async { self.downloadProgressHandler?.handler(self.downloadProgress) }
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        session.downloadTask(with: request)
    }

    /// Creates a `URLSessionTask` from the provided resume data.
    ///
    /// - Parameters:
    ///   - data:    `Data` used to resume the download.
    ///   - session: `URLSession` used to create the `URLSessionTask`.
    ///
    /// - Returns:   The `URLSessionTask` created.
    public func task(forResumeData data: Data, using session: URLSession) -> URLSessionTask {
        session.downloadTask(withResumeData: data)
    }

    /// Cancels the instance. Once cancelled, a `DownloadRequest` can no longer be resumed or suspended.
    ///
    /// - Note: This method will NOT produce resume data. If you wish to cancel and produce resume data, use
    ///         `cancel(producingResumeData:)` or `cancel(byProducingResumeData:)`.
    ///
    /// - Returns: The instance.
    @discardableResult
    override public func cancel() -> Self {
        cancel(producingResumeData: false)
    }

    /// Cancels the instance, optionally producing resume data. Once cancelled, a `DownloadRequest` can no longer be
    /// resumed or suspended.
    ///
    /// - Note: If `producingResumeData` is `true`, the `resumeData` property will be populated with any resume data, if
    ///         available.
    ///
    /// - Returns: The instance.
    @discardableResult
    public func cancel(producingResumeData shouldProduceResumeData: Bool) -> Self {
        cancel(optionallyProducingResumeData: shouldProduceResumeData ? { _ in } : nil)
    }

    /// Cancels the instance while producing resume data. Once cancelled, a `DownloadRequest` can no longer be resumed
    /// or suspended.
    ///
    /// - Note: The resume data passed to the completion handler will also be available on the instance's `resumeData`
    ///         property.
    ///
    /// - Parameter completionHandler: The completion handler that is called when the download has been successfully
    ///                                cancelled. It is not guaranteed to be called on a particular queue, so you may
    ///                                want use an appropriate queue to perform your work.
    ///
    /// - Returns:                     The instance.
    @discardableResult
    public func cancel(byProducingResumeData completionHandler: @escaping (_ data: Data?) -> Void) -> Self {
        cancel(optionallyProducingResumeData: completionHandler)
    }

    /// Internal implementation of cancellation that optionally takes a resume data handler. If no handler is passed,
    /// cancellation is performed without producing resume data.
    ///
    /// - Parameter completionHandler: Optional resume data handler.
    ///
    /// - Returns:                     The instance.
    private func cancel(optionallyProducingResumeData completionHandler: ((_ resumeData: Data?) -> Void)?) -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.cancelled) else { return }

            mutableState.state = .cancelled

            underlyingQueue.async { self.didCancel() }

            guard let task = mutableState.tasks.last as? URLSessionDownloadTask, task.state != .completed else {
                underlyingQueue.async { self.finish() }
                return
            }

            if let completionHandler {
                // Resume to ensure metrics are gathered.
                task.resume()
                task.cancel { resumeData in
                    self.mutableDownloadState.resumeData = resumeData
                    self.underlyingQueue.async { self.didCancelTask(task) }
                    completionHandler(resumeData)
                }
            } else {
                // Resume to ensure metrics are gathered.
                task.resume()
                task.cancel()
                self.underlyingQueue.async { self.didCancelTask(task) }
            }
        }

        return self
    }

    /// Validates the request, using the specified closure.
    ///
    /// - Note: If validation fails, subsequent calls to response handlers will have an associated error.
    ///
    /// - Parameter validation: `Validation` closure to validate the response.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: () -> Void = { [unowned self] in
            guard error == nil, let response else { return }

            let result = validation(request, response, fileURL)

            if case let .failure(error) = result {
                self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error)))
            }

            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  fileURL: fileURL,
                                  withResult: result)
        }

        validators.write { $0.append(validator) }

        return self
    }
}

// MARK: - UploadRequest

/// `DataRequest` subclass which handles `Data` upload from memory, file, or stream using `URLSessionUploadTask`.
public class UploadRequest: DataRequest {
    /// Type describing the origin of the upload, whether `Data`, file, or stream.
    public enum Uploadable {
        /// Upload from the provided `Data` value.
        case data(Data)
        /// Upload from the provided file `URL`, as well as a `Bool` determining whether the source file should be
        /// automatically removed once uploaded.
        case file(URL, shouldRemove: Bool)
        /// Upload from the provided `InputStream`.
        case stream(InputStream)
    }

    // MARK: Initial State

    /// The `UploadableConvertible` value used to produce the `Uploadable` value for this instance.
    public let upload: UploadableConvertible

    /// `FileManager` used to perform cleanup tasks, including the removal of multipart form encoded payloads written
    /// to disk.
    public let fileManager: FileManager

    // MARK: Mutable State

    /// `Uploadable` value used by the instance.
    public var uploadable: Uploadable?

    /// Creates an `UploadRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - convertible:        `UploadConvertible` value used to determine the type of upload to be performed.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - fileManager:        `FileManager` used to perform cleanup tasks, including the removal of multipart form
    ///                         encoded payloads written to disk.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    init(id: UUID = UUID(),
         convertible: UploadConvertible,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: EventMonitor?,
         interceptor: RequestInterceptor?,
         fileManager: FileManager,
         delegate: RequestDelegate) {
        upload = convertible
        self.fileManager = fileManager

        super.init(id: id,
                   convertible: convertible,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    /// Called when the `Uploadable` value has been created from the `UploadConvertible`.
    ///
    /// - Parameter uploadable: The `Uploadable` that was created.
    func didCreateUploadable(_ uploadable: Uploadable) {
        self.uploadable = uploadable

        eventMonitor?.request(self, didCreateUploadable: uploadable)
    }

    /// Called when the `Uploadable` value could not be created.
    ///
    /// - Parameter error: `AFError` produced by the failure.
    func didFailToCreateUploadable(with error: AFError) {
        self.error = error

        eventMonitor?.request(self, didFailToCreateUploadableWithError: error)

        retryOrFinish(error: error)
    }

    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        guard let uploadable else {
            fatalError("Attempting to create a URLSessionUploadTask when Uploadable value doesn't exist.")
        }

        switch uploadable {
        case let .data(data): return session.uploadTask(with: request, from: data)
        case let .file(url, _): return session.uploadTask(with: request, fromFile: url)
        case .stream: return session.uploadTask(withStreamedRequest: request)
        }
    }

    override func reset() {
        // Uploadable must be recreated on every retry.
        uploadable = nil

        super.reset()
    }

    /// Produces the `InputStream` from `uploadable`, if it can.
    ///
    /// - Note: Calling this method with a non-`.stream` `Uploadable` is a logic error and will crash.
    ///
    /// - Returns: The `InputStream`.
    func inputStream() -> InputStream {
        guard let uploadable else {
            fatalError("Attempting to access the input stream but the uploadable doesn't exist.")
        }

        guard case let .stream(stream) = uploadable else {
            fatalError("Attempted to access the stream of an UploadRequest that wasn't created with one.")
        }

        eventMonitor?.request(self, didProvideInputStream: stream)

        return stream
    }

    override public func cleanup() {
        defer { super.cleanup() }

        guard
            let uploadable,
            case let .file(url, shouldRemove) = uploadable,
            shouldRemove
        else { return }

        try? fileManager.removeItem(at: url)
    }
}

/// A type that can produce an `UploadRequest.Uploadable` value.
public protocol UploadableConvertible {
    /// Produces an `UploadRequest.Uploadable` value from the instance.
    ///
    /// - Returns: The `UploadRequest.Uploadable`.
    /// - Throws:  Any `Error` produced during creation.
    func createUploadable() throws -> UploadRequest.Uploadable
}

extension UploadRequest.Uploadable: UploadableConvertible {
    public func createUploadable() throws -> UploadRequest.Uploadable {
        self
    }
}

/// A type that can be converted to an upload, whether from an `UploadRequest.Uploadable` or `URLRequestConvertible`.
public protocol UploadConvertible: UploadableConvertible & URLRequestConvertible {}
