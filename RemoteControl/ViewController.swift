import Alamofire
import Cocoa
import Starscream
import Vision

private enum Regex {
    static let ipAddress = "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
    static let hostname = "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])$"
    static let anywhereIPAddress = "^http://((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])):\\d+/"
}

private extension String {
    var isValidIPv4Address: Bool {
        return matches(pattern: Regex.ipAddress)
    }

    var isValidHostname: Bool {
        return matches(pattern: Regex.hostname)
    }

    private func matches(pattern: String) -> Bool {
        return range(of: pattern,
                     options: .regularExpression,
                     range: nil,
                     locale: nil) != nil
    }
}

extension StringProtocol {
    var asciiValues: [UInt8] { compactMap(\.asciiValue) }
}

final class ViewController: NSViewController, WebSocketDelegate {
    @IBOutlet var effectView: NSVisualEffectView!

    private var hasAXPermission = false
    private var hasSCPermission = false

    private var eventMonitors = [Any]()

    override func viewDidLoad() {
        super.viewDidLoad()

        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] (event) -> NSEvent? in
            guard let self = self, event.window == self.view.window else { return event }
            
            self.flagsChanged(with: event)
            return nil
        }!)

        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] (event) -> NSEvent? in
            guard let self = self, event.window == self.view.window else { return event }
            
            if event.modifierFlags.contains(.function) {
                return event
            }
            
            self.keyDown(with: event)
            return nil
        }!)

        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] (event) -> NSEvent? in
            guard let self = self, event.window == self.view.window else { return event }
            
            if event.modifierFlags.contains(.function) {
                return event
            }
            
            self.keyUp(with: event)
            return nil
        }!)

        hasSCPermission = CGPreflightScreenCaptureAccess()
        if !hasSCPermission {
            hasSCPermission = CGRequestScreenCaptureAccess()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillBecomeActiveNotification(_:)), name: NSApplication.willBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActiveNotification(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }
    
    @objc
    private func applicationWillTerminate(_ aNotification: Notification) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("os.exit()")
        socketWrite(["mode": "quit"], to: connectedSocket)
    }
    
    private var pausePlayerAutoActivate = false
    
    @objc
    private func applicationWillBecomeActiveNotification(_ aNotification: Notification) {
        guard !pausePlayerAutoActivate,
              let playerPID = playerPID,
              let playerApp = NSRunningApplication(processIdentifier: pid_t(playerPID))
        else {
            return
        }
        
        pausePlayerAutoActivate = true
        let activated = playerApp.activate()
        if activated {
            NSRunningApplication(processIdentifier: getpid())?
                .activate(options: .activateIgnoringOtherApps)
        }
    }
    
    @objc
    private func applicationDidResignActiveNotification(_ aNotification: Notification) {
        guard pausePlayerAutoActivate else {
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 3.0) { [unowned self] in
            pausePlayerAutoActivate = false
        }
    }

    private var didDisplayFirstPrompt = false
    private var didDisplayAXPrompt = false

    override func viewDidAppear() {
        super.viewDidAppear()
        
        view.window?.titlebarAppearsTransparent = UserDefaults.standard.bool(forKey: "ch.xxtou.RemoteControl.defaults.titlebarAppearsTransparent")

        if !didDisplayFirstPrompt {
            if hasAXPermission && hasSCPermission {
                promptWaitPlayer()
            } else {
                promptWaitPermission()
            }
            didDisplayFirstPrompt = true
        }
    }

    private func promptWaitPermission() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Wait for permission…", comment: "")
        alert.informativeText = NSLocalizedString("“Remote Control” requires “Accessibility” and ”Screen Recording“ permissions to continue.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Terminate", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.buttons.last?.isHidden = true
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        indicator.style = .spinning
        indicator.sizeToFit()
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.beginSheetModal(for: view.window!) { [unowned self] resp in
            if resp == .alertSecondButtonReturn {
                promptWaitPlayer()
            } else {
                NSApp.terminate(nil)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))

                hasSCPermission = CGPreflightScreenCaptureAccess()
                if hasSCPermission && !hasAXPermission && !didDisplayAXPrompt {
                    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    hasAXPermission = AXIsProcessTrustedWithOptions(options)
                    didDisplayAXPrompt = true
                } else {
                    hasAXPermission = AXIsProcessTrustedWithOptions(nil)
                }
            } while !hasAXPermission || !hasSCPermission

            DispatchQueue.main.async { [unowned self] in
                view.window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            }
        }
    }

    private var playerPID: UInt32?
    private var playerWindowID: UInt32?
    private var playerWindowBounds: CGRect?

    private func updatePlayerState() -> Bool {
        let windowList: CFArray? = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

        var windowFound = false
        for entry in windowList! as Array {
            let ownerName: String = entry.object(forKey: kCGWindowOwnerName) as? String ?? "N/A"
            let windowName: String = entry.object(forKey: kCGWindowName) as? String ?? "N/A"
            if ownerName.contains("QuickTime") && (windowName.contains("Recording") || windowName.contains("录制")) {
                if let playerBoundsDict = entry.object(forKey: kCGWindowBounds) {
                    playerPID = entry.object(forKey: kCGWindowOwnerPID) as? UInt32
                    playerWindowID = entry.object(forKey: kCGWindowNumber) as? UInt32
                    playerWindowBounds = CGRect(dictionaryRepresentation: playerBoundsDict as! CFDictionary)

                    windowFound = true
                }
                break
            }
        }

        return windowFound
    }

    private func promptWaitPlayer() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Wait for “QuickTime Player”…", comment: "")
        alert.informativeText = NSLocalizedString("Launch “QuickTime Player” and open a new movie recording window to continue.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Terminate", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.buttons.last?.isHidden = true
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        indicator.style = .spinning
        indicator.sizeToFit()
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.beginSheetModal(for: view.window!) { [unowned self] resp in
            if resp == .alertSecondButtonReturn {
                beginMonitorPlayer()
                promptAskAddress()
            } else {
                NSApp.terminate(nil)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            } while !updatePlayerState()

            DispatchQueue.main.async { [unowned self] in
                view.window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            }
        }
    }

    private var syncTimer: Timer?

    private func beginMonitorPlayer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [unowned self] _ in

            guard let window = view.window else {
                return
            }

            let windowFound = updatePlayerState()
            if windowFound && !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else if !windowFound && window.isVisible {
                window.orderOut(nil)
            }

            if windowFound {
                if let bounds = playerWindowBounds, let screenHeight = window.screen?.frame.height {
                    window.setContentSize(bounds.size)

                    var origin = bounds.origin
                    origin.y = screenHeight - (origin.y + bounds.height)
                    window.setFrameOrigin(origin)

                    effectView.alphaValue = 0
                }
            }
        }
    }

    private let addressDefaultsKey = "ch.xxtou.RemoteControl.defaults.address"
    private var deviceAddress: String?
    private var deviceLabel: String?
    private var deviceAPIBase: String? {
        guard let deviceAddress = deviceAddress else {
            return nil
        }
        return "http://\(deviceAddress):46952/"
    }

    private func promptAskAddress() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("XXTouch", comment: "")
        alert.informativeText = NSLocalizedString("Open “XXTouch”, turn on “Remote Address” switch and enter the ip address shown below.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Connect", comment: ""))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 228, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: addressDefaultsKey) ?? ""
        field.alignment = .center
        alert.accessoryView = field
        alert.beginSheetModal(for: view.window!) { [unowned self] resp in
            if resp == .alertFirstButtonReturn {
                if field.stringValue.isValidIPv4Address {
                    UserDefaults.standard.set(field.stringValue, forKey: addressDefaultsKey)
                    deviceAddress = field.stringValue
                    
                    endCaptureAddress()
                    promptConnection()
                } else {
                    promptModalMessage(NSLocalizedString("Invalid Address", comment: ""), NSLocalizedString("Please input a valid IPv4 address.", comment: "")) { [unowned self] _ in
                        if resp == .alertFirstButtonReturn {
                            promptAskAddress()
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }

        endCaptureAddress()
        beginCaptureAddress { capturedAddress in
            field.stringValue = capturedAddress
        }
    }

    private var captureTimer: Timer?

    private func beginCaptureAddress(resultHandler: @escaping (String) -> Void) {
        let addressRegex = try! NSRegularExpression(pattern: Regex.anywhereIPAddress)
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [unowned self] timer in
            guard let playerWindowID = playerWindowID,
                  let playerWindowBounds = playerWindowBounds
            else {
                return
            }

            guard let playerWindowImage = CGWindowListCreateImage(playerWindowBounds, [.optionOnScreenBelowWindow, .optionIncludingWindow, .excludeDesktopElements], CGWindowID(playerWindowID), [.boundsIgnoreFraming, .shouldBeOpaque, .nominalResolution]) else {
                return
            }

            // Create a new image-request handler.
            let requestHandler = VNImageRequestHandler(cgImage: playerWindowImage)

            // Create a new request to recognize text.
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations =
                    request.results as? [VNRecognizedTextObservation] else {
                    return
                }
                let recognizedStrings = observations.compactMap { observation in
                    // Return the string of the top VNRecognizedText instance.
                    observation.topCandidates(1).first?.string
                }

                // Process the recognized strings.
                for needle in recognizedStrings {
                    if let needleMatch = addressRegex.firstMatch(in: needle, range: NSRange(location: 0, length: needle.count))
                    {
                        if needleMatch.numberOfRanges >= 2 {
                            let recognizedAddress = (needle as NSString).substring(with: needleMatch.range(at: 1))
                            resultHandler(recognizedAddress)
                        }
                    }
                }
            }

            do {
                // Perform the text-recognition request.
                try requestHandler.perform([request])
            } catch {
                print("Unable to perform the requests: \(error).")
            }
        })
    }

    private func endCaptureAddress() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    private func promptModalMessage(_ message: String, _ informative: String?, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.addButton(withTitle: NSLocalizedString("Try Again", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Terminate", comment: ""))
        alert.messageText = message
        alert.informativeText = informative ?? NSLocalizedString("An unknown error occurred.", comment: "")
        alert.beginSheetModal(for: view.window!) { resp in
            completionHandler(resp)
        }
    }
    
    private func fetchRunningStatus(completionHandler: @escaping (String?) -> Void) {
        guard let deviceAPIBase = deviceAPIBase else {
            completionHandler(nil)
            return
        }
        AF.request(deviceAPIBase + "status", method: .post)
            .response { response in
                if let data = response.data {
                    completionHandler(String(data: data, encoding: .utf8))
                } else {
                    completionHandler(nil)
                }
            }
    }

    private func promptConnection() {
        guard let deviceAddress = deviceAddress else {
            return
        }

        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Connect to “%@”…", comment: ""), deviceAddress)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.isHidden = true
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        indicator.style = .spinning
        indicator.sizeToFit()
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.beginSheetModal(for: view.window!)

        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in
            fetchAssignedName { [unowned self] name in
                if let name = name {
                    alert.messageText = String(format: NSLocalizedString("Connect to “%@”…", comment: ""), name)
                }
                fetchRunningStatus { [unowned self] status in
                    if status == "f00" {
                        DispatchQueue.main.async { [unowned self] in
                            view.window?.endSheet(alert.window)
                        }
                        
                        DispatchQueue.main.async { [unowned self] in
                            deviceLabel = name ?? deviceAddress
                            promptPreflight()
                        }
                        return
                    }
                    
                    beginStarscream { [unowned self] firstConnected, firstError in
                        DispatchQueue.main.async { [unowned self] in
                            view.window?.endSheet(alert.window)
                        }
                        
                        guard firstConnected else {
                            DispatchQueue.main.async { [unowned self] in
                                deviceLabel = name ?? deviceAddress
                                promptPreflight()
                            }
                            return
                        }
                        
                        // Connected now...
                    }
                }
            }
        }
    }
    
    private func fetchAssignedName(completionHandler: @escaping (String?) -> Void) {
        guard let deviceAPIBase = deviceAPIBase else {
            completionHandler(nil)
            return
        }
        AF.request(deviceAPIBase + "devicename", method: .get)
            .response { response in
                if let data = response.data {
                    completionHandler(String(data: data, encoding: .utf8))
                } else {
                    completionHandler(nil)
                }
            }
    }
    
    private func promptPreflight() {
        guard let deviceLabel = deviceLabel else {
            return
        }
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Control Confirm", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Will begin control “%@”, continue?", comment: ""), deviceLabel)
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: view.window!) { [unowned self] resp in
            if resp == .alertFirstButtonReturn {
                promptSpawn(deviceLabel: deviceLabel)
            } else {
                promptAskAddress()
            }
        }
    }
    
    private func promptSpawn(deviceLabel: String) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Connect to “%@”…", comment: ""), deviceLabel)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.isHidden = true
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        indicator.style = .spinning
        indicator.sizeToFit()
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.beginSheetModal(for: view.window!)
        
        spawnControlSession { [unowned self] spawnSucceed, spawnErrorMessage in
            DispatchQueue.main.async { [unowned self] in
                view.window?.endSheet(alert.window)
            }
            
            guard spawnSucceed else {
                DispatchQueue.main.async { [unowned self] in
                    promptModalMessage(NSLocalizedString("Connection Failed", comment: ""), spawnErrorMessage) { [unowned self] resp in
                        if resp == .alertFirstButtonReturn {
                            promptAskAddress()
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                }
                return
            }
            
            beginStarscream { [unowned self] secondConnected, connectionErrorMessage in
                guard secondConnected else {
                    DispatchQueue.main.async { [unowned self] in
                        promptModalMessage(NSLocalizedString("Connection Failed", comment: ""), connectionErrorMessage) { [unowned self] resp in
                            if resp == .alertFirstButtonReturn {
                                promptAskAddress()
                            } else {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    private func spawnControlSession(completionHandler: @escaping (Bool, String?) -> Void) {
        guard let deviceAPIBase = deviceAPIBase else {
            completionHandler(false, nil)
            return
        }
        
        guard let scriptURL = Bundle.main.url(forResource: "screen", withExtension: "lua") else {
            completionHandler(false, nil)
            return
        }
        
        do {
            let scriptData = try Data(contentsOf: scriptURL)
            AF.upload(scriptData, to: deviceAPIBase + "spawn").response { resp in
                guard let data = resp.data else {
                    completionHandler(false, resp.error?.localizedDescription)
                    return
                }
                guard let respObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completionHandler(false, NSLocalizedString("Failed to decode response.", comment: ""))
                    return
                }
                guard let respCode = respObject["code"] as? Int else {
                    completionHandler(false, NSLocalizedString("Invalid response.", comment: ""))
                    return
                }
                guard respCode == 0 else {
                    completionHandler(false, respObject["message"] as? String)
                    return
                }
                completionHandler(true, nil)
            }
        } catch {
            completionHandler(false, error.localizedDescription)
        }
    }
    
    private var isConnected = false
    private var connectedSocket: WebSocket?
    
    private var connectionTimer: Timer?
    private var heartTimer: Timer?
    
    private var screenWidth: CGFloat?
    private var screenHeight: CGFloat?
    
    private func beginStarscream(completionHandler: @escaping (Bool, String?) -> Void) {
        guard let deviceAddress = deviceAddress else {
            completionHandler(false, nil)
            return
        }
        
        var request = URLRequest(url: URL(string: "ws://\(deviceAddress):46968")!)
        request.timeoutInterval = 3.0
        request.setValue("RC", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        
        let socket = WebSocket(request: request)
        socket.delegate = self
        socket.respondToPingWithPong = true
        socket.connect()
        connectedSocket = socket
        
        var timeoutCount = 0
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [unowned self] timer in
            if isConnected {
                invalidateConnectionTimer()
                completionHandler(true, nil)
                return
            }
            
            timeoutCount += 1
            if timeoutCount > 3 {
                invalidateConnectionTimer()
                completionHandler(false, NSLocalizedString("Connection timeout.", comment: ""))
                return
            }
        })
    }
    
    private func invalidateConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }
    
    private func invalidateHeartTimer() {
        heartTimer?.invalidate()
        heartTimer = nil
    }
    
    private func endStarscream() {
        connectedSocket?.forceDisconnect()
        invalidateConnectionTimer()
        invalidateHeartTimer()
        connectedSocket = nil
    }
    
    func socketWrite(_ object: Any, to socket: WebSocket) {
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            socket.write(stringData: data, completion: nil)
        }
    }
    
    func socketRead(string: String) -> Any? {
        return try? JSONSerialization.jsonObject(with: string.data(using: .utf8)!)
    }
    
    func socketRead(data: Data) -> Any? {
        return try? JSONSerialization.jsonObject(with: data)
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        var failureReason: String? = nil
        
        switch event {
        case .connected(let headers):
            print("websocket is connected: \(headers)")
            isConnected = true
            
            if let deviceLabel = deviceLabel {
                view.window?.subtitle = deviceLabel
                NSApp.dockTile.badgeLabel = deviceLabel
            }
            
            heartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [unowned self] timer in
                socketWrite(["mode": "heart"], to: client)
            })
        case .disconnected(let reason, let code):
            print("websocket is disconnected: \(reason) with code: \(code)")
            isConnected = false
            failureReason = reason
        case .text(let string):
            if let respObject = socketRead(string: string) as? [String: Any] {
                if respObject["mode"] as? String == "heart" {
                    if let sizeDict = respObject["size"] as? [String: Any]
                    {
                        if let width = sizeDict["w"] as? CGFloat,
                           let height = sizeDict["h"] as? CGFloat
                        {
                            screenWidth = width
                            screenHeight = height
                        }
                    }
                    socketWrite(["mode": "heart"], to: client)
                }
                else if respObject["mode"] as? String == "clipboard_read" {
                    if let clipboardText = respObject["data"] as? String {
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(clipboardText, forType: .string)
                    }
                }
                else if respObject["mode"] as? String == "save_snapshot" {
                    if let snapshotText = respObject["data"] as? String,
                       let snapshotData = Data(base64Encoded: snapshotText)
                    {
                        let savedURL = saveScreenshot(snapshotData)
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                }
            }
        case .binary(let data):
            _ = socketRead(data: data)
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            isConnected = false
            failureReason = NSLocalizedString("Connection cancelled.", comment: "")
        case .error(let error):
            isConnected = false
            failureReason = error?.localizedDescription
        }
        
        if !isConnected, let failureReason = failureReason {
            endStarscream()
            promptModalMessage(NSLocalizedString("Connection Interrupted", comment: ""), failureReason) { [unowned self] resp in
                if resp == .alertFirstButtonReturn {
                    promptAskAddress()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
    
    private static var screenshotDateFormatter: DateFormatter =
    {
        let formatter = DateFormatter.init()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()
    
    private func saveScreenshot(_ data: Data) -> URL {
        let picturesDirectoryURL = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("RemoteControl")
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: picturesDirectoryURL.path, isDirectory: &isDirectory) {
            try? FileManager.default.createDirectory(at: picturesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        var picturesURL = picturesDirectoryURL
        picturesURL.appendPathComponent("screenshot_\(Self.screenshotDateFormatter.string(from: Date.init()))")
        picturesURL.appendPathExtension("png")
        try? data.write(to: picturesURL)
        return picturesURL
    }
    

    // MARK: -
    
    private func remoteLocation(with event: NSEvent) -> CGPoint? {
        guard let screenWidth = screenWidth,
              let screenHeight = screenHeight
        else {
            return nil
        }
        
        let locInView = view.convert(event.locationInWindow, from: nil)
        let isStandard = (view.bounds.height > view.bounds.width && screenHeight > screenWidth) || (view.bounds.height < view.bounds.width && screenHeight < screenWidth)
        
        return isStandard ? CGPoint(
            x: min(max(locInView.x / view.bounds.width, 0.0), 1.0) * screenWidth,
            y: min(max(locInView.y / view.bounds.height, 0.0), 1.0) * screenHeight
        ) : CGPoint(
            x: min(max(locInView.x / view.bounds.width, 0.0), 1.0) * screenHeight,
            y: min(max(locInView.y / view.bounds.height, 0.0), 1.0) * screenWidth
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        guard let locInRemote = remoteLocation(with: event) else {
            return
        }
        
        debugPrint(String(format: "touch.down(%d, %d)", Int(locInRemote.x), Int(locInRemote.y)))
        socketWrite(["mode": "down", "x": Int(locInRemote.x), "y": Int(locInRemote.y)], to: connectedSocket)
    }

    override func mouseUp(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        guard let locInRemote = remoteLocation(with: event) else {
            return
        }
        
        debugPrint(String(format: "touch.up(%d, %d)", Int(locInRemote.x), Int(locInRemote.y)))
        socketWrite(["mode": "up", "x": Int(locInRemote.x), "y": Int(locInRemote.y)], to: connectedSocket)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        guard let locInRemote = remoteLocation(with: event) else {
            return
        }
        
        debugPrint(String(format: "touch.move(%d, %d)", Int(locInRemote.x), Int(locInRemote.y)))
        socketWrite(["mode": "move", "x": Int(locInRemote.x), "y": Int(locInRemote.y)], to: connectedSocket)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.down('HOMEBUTTON')")
        socketWrite(["mode": "home_down"], to: connectedSocket)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.up('HOMEBUTTON')")
        socketWrite(["mode": "home_up"], to: connectedSocket)
    }

    override func rightMouseDragged(with event: NSEvent) {
        debugPrint("right dragged")
    }
    
    // References:
    // https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/keyCode
    // https://developer.mozilla.org/en-US/docs/Web/API/UI_Events/Keyboard_event_code_values
    private static let browserKeyCodeMapping: [UInt16: UInt16] = [
        0x00: 0x41,
        0x01: 0x53,
        0x02: 0x44,
        0x03: 0x46,
        0x04: 0x48,
        0x05: 0x47,
        0x06: 0x5A,
        0x07: 0x58,
        0x08: 0x43,
        0x09: 0x56,
        0x0B: 0x42,
        0x0C: 0x51,
        0x0D: 0x57,
        0x0E: 0x45,
        0x0F: 0x52,
        0x10: 0x59,
        0x11: 0x54,
        0x12: 0x31,
        0x13: 0x32,
        0x14: 0x33,
        0x15: 0x34,
        0x16: 0x36,
        0x17: 0x35,
        0x18: 0xBB,
        0x19: 0x39,
        0x1A: 0x37,
        0x1B: 0xBD,
        0x1C: 0x38,
        0x1D: 0x30,
        0x1E: 0xDD,
        0x1F: 0x4F,
        0x20: 0x55,
        0x21: 0xDB,
        0x22: 0x49,
        0x23: 0x50,
        0x25: 0x4C,
        0x26: 0x4A,
        0x27: 0xDE,
        0x28: 0x4B,
        0x29: 0xBA,
        0x2A: 0xDC,
        0x2B: 0xBC,
        0x2C: 0xBF,
        0x2D: 0x4E,
        0x2E: 0x4D,
        0x2F: 0xBE,
        0x32: 0xC0,
        0x41: 0x6E,
        0x43: 0x6A,
        0x45: 0x6B,
        0x47: 0x0C,
        0x4B: 0x6F,
        0x4C: 0x0D,
        0x4E: 0x6D,
        0x51: 0xBB,
        0x52: 0x60,
        0x53: 0x61,
        0x54: 0x62,
        0x55: 0x63,
        0x56: 0x64,
        0x57: 0x65,
        0x58: 0x66,
        0x59: 0x67,
        0x5B: 0x68,
        0x5C: 0x69,
        0x24: 0x0D,
        0x30: 0x09,
        0x31: 0x20,
        0x33: 0x08,
        0x35: 0x1B,
        0x37: 0x5B,
        0x38: 0x10,
        0x39: 0x14,
        0x3A: 0x12,
        0x3B: 0x11,
        0x3C: 0x10,
        0x3D: 0x12,
        0x3E: 0x11,
        0x40: 0x80,
        0x48: 0xB7,
        0x49: 0xB6,
        0x4A: 0xB5,
        0x4F: 0x81,
        0x50: 0x82,
        0x5A: 0x83,
        0x60: 0x74,
        0x61: 0x75,
        0x62: 0x76,
        0x63: 0x72,
        0x64: 0x77,
        0x65: 0x78,
        0x67: 0x7A,
        0x69: 0x7C,
        0x6A: 0x7F,
        0x6B: 0x7D,
        0x6D: 0x79,
        0x6F: 0x7B,
        0x71: 0x7E,
        0x72: 0x2D,
        0x73: 0x24,
        0x74: 0x21,
        0x75: 0x2E,
        0x76: 0x73,
        0x77: 0x23,
        0x78: 0x71,
        0x79: 0x22,
        0x7A: 0x70,
        0x7B: 0x25,
        0x7C: 0x27,
        0x7D: 0x28,
        0x7E: 0x26,
    ]
    
    private func browserKeyCode(with event: NSEvent) -> UInt16? {
        guard let mappedKeyCode = Self.browserKeyCodeMapping[event.keyCode] else {
            debugPrint(String(format: "unknown keyCode = %d", event.keyCode))
            return nil
        }
        return mappedKeyCode
    }
    
    private var modifierFlagState = [NSEvent.ModifierFlags.RawValue: Bool]()

    override func flagsChanged(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        var isDown: Bool?
        
        if isDown == nil
        {
            let capsLockWasDown = modifierFlagState[NSEvent.ModifierFlags.capsLock.rawValue] ?? false
            let capsLockIsDown = event.modifierFlags.contains(.capsLock)
            if capsLockIsDown != capsLockWasDown {
                if capsLockIsDown {
                    debugPrint("flag .capsLock down")
                } else {
                    debugPrint("flag .capsLock up")
                }
                isDown = capsLockIsDown
                modifierFlagState[NSEvent.ModifierFlags.capsLock.rawValue] = capsLockIsDown
            }
        }
        
        if isDown == nil
        {
            let shiftWasDown = modifierFlagState[NSEvent.ModifierFlags.shift.rawValue] ?? false
            let shiftIsDown = event.modifierFlags.contains(.shift)
            if shiftIsDown != shiftWasDown {
                if shiftIsDown {
                    debugPrint("flag .shift down")
                } else {
                    debugPrint("flag .shift up")
                }
                isDown = shiftIsDown
                modifierFlagState[NSEvent.ModifierFlags.shift.rawValue] = shiftIsDown
            }
        }
        
        if isDown == nil
        {
            let controlWasDown = modifierFlagState[NSEvent.ModifierFlags.control.rawValue] ?? false
            let controlIsDown = event.modifierFlags.contains(.control)
            if controlIsDown != controlWasDown {
                if controlIsDown {
                    debugPrint("flag .control down")
                } else {
                    debugPrint("flag .control up")
                }
                isDown = controlIsDown
                modifierFlagState[NSEvent.ModifierFlags.control.rawValue] = controlIsDown
            }
        }
        
        if isDown == nil
        {
            let optionWasDown = modifierFlagState[NSEvent.ModifierFlags.option.rawValue] ?? false
            let optionIsDown = event.modifierFlags.contains(.option)
            if optionIsDown != optionWasDown {
                if optionIsDown {
                    debugPrint("flag .option down")
                } else {
                    debugPrint("flag .option up")
                }
                isDown = optionIsDown
                modifierFlagState[NSEvent.ModifierFlags.option.rawValue] = optionIsDown
            }
        }
        
        if isDown == nil
        {
            let commandWasDown = modifierFlagState[NSEvent.ModifierFlags.command.rawValue] ?? false
            let commandIsDown = event.modifierFlags.contains(.command)
            if commandIsDown != commandWasDown {
                if commandIsDown {
                    debugPrint("flag .command down")
                } else {
                    debugPrint("flag .command up")
                }
                isDown = commandIsDown
                modifierFlagState[NSEvent.ModifierFlags.command.rawValue] = commandIsDown
            }
        }
        
        if isDown == nil
        {
            let numericPadWasDown = modifierFlagState[NSEvent.ModifierFlags.numericPad.rawValue] ?? false
            let numericPadIsDown = event.modifierFlags.contains(.numericPad)
            if numericPadIsDown != numericPadWasDown {
                if numericPadIsDown {
                    debugPrint("flag .numericPad down")
                } else {
                    debugPrint("flag .numericPad up")
                }
                isDown = numericPadIsDown
                modifierFlagState[NSEvent.ModifierFlags.numericPad.rawValue] = numericPadIsDown
            }
        }
        
        if isDown == nil
        {
            let helpWasDown = modifierFlagState[NSEvent.ModifierFlags.help.rawValue] ?? false
            let helpIsDown = event.modifierFlags.contains(.help)
            if helpIsDown != helpWasDown {
                if helpIsDown {
                    debugPrint("flag .help down")
                } else {
                    debugPrint("flag .help up")
                }
                isDown = helpIsDown
                modifierFlagState[NSEvent.ModifierFlags.help.rawValue] = helpIsDown
            }
        }
        
        if isDown == nil
        {
            let functionWasDown = modifierFlagState[NSEvent.ModifierFlags.function.rawValue] ?? false
            let functionIsDown = event.modifierFlags.contains(.function)
            if functionIsDown != functionWasDown {
                if functionIsDown {
                    debugPrint("flag .function down")
                } else {
                    debugPrint("flag .function up")
                }
                isDown = functionIsDown
                modifierFlagState[NSEvent.ModifierFlags.function.rawValue] = functionIsDown
            }
        }
        
        if let isDown = isDown,
           let keyCode = browserKeyCode(with: event)
        {
            if isDown {
                debugPrint(String(format: "key.down(%d)", keyCode))
                socketWrite(["mode": "input_down", "key": keyCode], to: connectedSocket)
            } else {
                debugPrint(String(format: "key.up(%d)", keyCode))
                socketWrite(["mode": "input_up", "key": keyCode], to: connectedSocket)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        if let keyCode = browserKeyCode(with: event) {
            if event.isARepeat {
                debugPrint(String(format: "key.up(%d)", keyCode))
                socketWrite(["mode": "input_up", "key": keyCode], to: connectedSocket)
            }
            
            debugPrint(String(format: "key.down(%d)", keyCode))
            socketWrite(["mode": "input_down", "key": keyCode], to: connectedSocket)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        if let keyCode = browserKeyCode(with: event) {
            debugPrint(String(format: "key.up(%d)", keyCode))
            socketWrite(["mode": "input_up", "key": keyCode], to: connectedSocket)
        }
    }
    
    override func otherMouseDown(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.down('POWER')")
        socketWrite(["mode": "power_down"], to: connectedSocket)
    }
    
    override func otherMouseUp(with event: NSEvent) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.up('POWER')")
        socketWrite(["mode": "power_up"], to: connectedSocket)
    }
    
    override func otherMouseDragged(with event: NSEvent) {
        debugPrint("other dragged")
    }
    
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
    
    @IBAction func pressHomeButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('HOMEBUTTON')")
        socketWrite(["mode": "home"], to: connectedSocket)
    }
    
    @IBAction func pressPowerButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('POWER')")
        socketWrite(["mode": "power"], to: connectedSocket)
    }
    
    @IBAction func pressMuteButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('MUTE')")
        socketWrite(["mode": "mute"], to: connectedSocket)
    }
    
    @IBAction func pressVolumeUpButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('VOLUMEUP')")
        socketWrite(["mode": "volume_increment"], to: connectedSocket)
    }
    
    @IBAction func pressVolumeDownButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('VOLUMEDOWN')")
        socketWrite(["mode": "volume_decrement"], to: connectedSocket)
    }
    
    @IBAction func toggleKeyboard(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('SHOW_HIDE_KEYBOARD')")
        socketWrite(["mode": "toggle_keyboard"], to: connectedSocket)
    }
    
    @IBAction func sendClipboardText(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        let pasteboard = NSPasteboard.general
        if let copiedString = pasteboard.string(forType: .string) {
            debugPrint(String(format: "key.send_text('%@')", copiedString))
            socketWrite(["mode": "send_text", "data": copiedString], to: connectedSocket)
        }
    }
    
    @IBAction func toggleTransparentTitleBar(_ sender: NSMenuItem) {
        if let window = view.window {
            window.titlebarAppearsTransparent = !window.titlebarAppearsTransparent
            UserDefaults.standard.set(window.titlebarAppearsTransparent, forKey: "ch.xxtou.RemoteControl.defaults.titlebarAppearsTransparent")
        }
    }
    
    @IBAction func clipboardCopyFromRemote(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        socketWrite(["mode": "clipboard_read"], to: connectedSocket)
    }
    
    @IBAction func clipboardCopyToRemote(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        let pasteboard = NSPasteboard.general
        if let copiedString = pasteboard.string(forType: .string) {
            debugPrint(String(format: "pasteboard.write('%@')", copiedString))
            socketWrite(["mode": "clipboard", "data": copiedString], to: connectedSocket)
        }
    }
    
    @IBAction func pressSnapshotButton(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("key.press('SNAPSHOT')")
        socketWrite(["mode": "snapshot"], to: connectedSocket)
    }
    
    @IBAction func windowOrderBack(_ sender: NSMenuItem) {
        guard let playerWindowID = playerWindowID else {
            return
        }
        
        view.window?.order(.below, relativeTo: Int(playerWindowID))
    }
    
    @IBAction func takeScreenshot(_ sender: NSMenuItem) {
        guard let connectedSocket = connectedSocket else {
            return
        }
        
        debugPrint("screen.image():png_data()")
        socketWrite(["mode": "save_snapshot"], to: connectedSocket)
    }
    
    @IBAction func copyOCRResults(_ sender: NSMenuItem) {
        guard let playerWindowID = playerWindowID,
              let playerWindowBounds = playerWindowBounds
        else {
            return
        }

        guard let playerWindowImage = CGWindowListCreateImage(playerWindowBounds, [.optionOnScreenBelowWindow, .optionIncludingWindow, .excludeDesktopElements], CGWindowID(playerWindowID), [.boundsIgnoreFraming, .shouldBeOpaque, .nominalResolution]) else {
            return
        }
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Recognizing…", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.isHidden = true
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        indicator.style = .spinning
        indicator.sizeToFit()
        indicator.startAnimation(nil)
        alert.accessoryView = indicator
        alert.beginSheetModal(for: view.window!)

        // Create a new image-request handler.
        let requestHandler = VNImageRequestHandler(cgImage: playerWindowImage)

        // Create a new request to recognize text.
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations =
                request.results as? [VNRecognizedTextObservation] else {
                return
            }
            let recognizedStrings = observations.compactMap { observation in
                // Return the string of the top VNRecognizedText instance.
                observation.topCandidates(1).first?.string
            }

            // Process the recognized strings.
            let recognizedContent = recognizedStrings.joined(separator: "\n")
            DispatchQueue.main.async { [unowned self] in
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(recognizedContent, forType: .string)
                
                view.window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            }
        }
        
        request.recognitionLevel = .accurate

        do {
            // Perform the text-recognition request.
            try requestHandler.perform([request])
        } catch {
            print("Unable to perform the requests: \(error).")
        }
    }
}
