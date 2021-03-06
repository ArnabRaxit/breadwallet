//
//  BRWebViewController.swift
//  BreadWallet
//
//  Created by Samuel Sutch on 12/10/15.
//  Copyright (c) 2016 breadwallet LLC
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

import Foundation
import UIKit
import WebKit


@available(iOS 8.0, *)
@objc open class BRWebViewController : UIViewController, WKNavigationDelegate, BRWebSocketClient {
    var wkProcessPool: WKProcessPool
    var webView: WKWebView?
    var bundleName: String
    var server = BRHTTPServer()
    var debugEndpoint: String? // = "http://localhost:8080"
    var mountPoint: String
    // didLoad should be set to true within didLoadTimeout otherwise a view will be shown which
    // indicates some error. this is to prevent the white-screen-of-death where there is some
    // javascript exception (or other error) that prevents the content from loading
    var didLoad = false
    var didAppear = false
    var didLoadTimeout = 2500
    // we are also a socket server which sends didview/didload events to the listening client(s)
    var sockets = [String: BRWebSocket]()
    // this is the data that occasionally gets sent to the above connected sockets
    var webViewInfo: [String: Any] {
        return [
            "visible": didAppear,
            "loaded": didLoad,
        ]
    }
    var indexUrl: URL {
        return URL(string: "http://127.0.0.1:\(server.port)\(mountPoint)")!
    }
    
    init(bundleName name: String, mountPoint mp: String = "/") {
        wkProcessPool = WKProcessPool()
        bundleName = name
        mountPoint = mp
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func loadView() {
        didLoad = false
        
        let config = WKWebViewConfiguration()
        config.processPool = wkProcessPool
        config.allowsInlineMediaPlayback = false
        if #available(iOS 9.0, *) {
            config.allowsAirPlayForMediaPlayback = false
            config.requiresUserActionForMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = false
        }

        let request = URLRequest(url: indexUrl)
        
        view = UIView(frame: CGRect.zero)
        view.backgroundColor = UIColor(red:0.98, green:0.98, blue:0.98, alpha:1.0)
        
        webView = WKWebView(frame: CGRect.zero, configuration: config)
        webView?.navigationDelegate = self
        webView?.backgroundColor = UIColor(red:0.98, green:0.98, blue:0.98, alpha:1.0)
        _ = webView?.load(request)
        webView?.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(webView!)
        
        NotificationCenter.default.addObserver(forName: .UIApplicationDidBecomeActive, object: nil, queue: OperationQueue.main) { (_) in
            self.didAppear = true
            self.sendToAllSockets(data: self.webViewInfo)
        }
        NotificationCenter.default.addObserver(forName: .UIApplicationWillResignActive, object: nil, queue: OperationQueue.main) { (_) in
            self.didAppear = false
            self.sendToAllSockets(data: self.webViewInfo)
        }
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        edgesForExtendedLayout = .all
        self.beginDidLoadCountdown()
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        didAppear = true
        sendToAllSockets(data: webViewInfo)
    }
    
    override open func viewDidDisappear(_ animated: Bool) {
        didAppear = false
        sendToAllSockets(data: webViewInfo)
    }
    
    fileprivate func closeNow() {
        dismiss(animated: true, completion: nil)
    }
    
    // this should be called when the webview is expected to load content. if the content has not signaled
    // that is has loaded by didLoadTimeout then an alert will be shown allowing the user to back out 
    // of the faulty webview
    fileprivate func beginDidLoadCountdown() {
        let timeout = DispatchTime.now() + .milliseconds(self.didLoadTimeout)
        DispatchQueue.main.asyncAfter(deadline: timeout) {
            if self.didAppear && !self.didLoad {
                // if the webview did not load the first time lets refresh the bundle. occasionally the bundle
                // update can fail, so this update should fetch an entirely new copy
                let activity = BRActivityViewController(message: NSLocalizedString("Updating...", comment: ""))
                self.present(activity, animated: true, completion: nil)
                BRAPIClient.sharedClient.updateBundle(self.bundleName) { (err) in
                    if err != nil {
                        print("[BRWebViewController] error updating bundle: \(String(describing: err))")
                    }
                    // give the webview another chance to load
                    self.refresh()
                    // XXX(sam): log this event so we know how frequently it happens
                    DispatchQueue.main.asyncAfter(deadline: timeout) {
                        self.dismiss(animated: true) {
                            self.notifyUserOfLoadFailure()
                        }
                    }
                }
            }
        }
    }
    
    fileprivate func notifyUserOfLoadFailure() {
        if self.didAppear && !self.didLoad {
            let alert = UIAlertController.init(
                title: NSLocalizedString("Error", comment: ""),
                message: NSLocalizedString("There was an error loading the content. Please try again", comment: ""),
                preferredStyle: .alert
            )
            let action = UIAlertAction(title: NSLocalizedString("Dismiss", comment: ""), style: .default) { _ in
                self.closeNow()
            }
            alert.addAction(action)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    // signal to the presenter that the webview content successfully loaded
    fileprivate func webviewDidLoad() {
        didLoad = true
        sendToAllSockets(data: webViewInfo)
    }
    
    open func startServer() {
        do {
            if !server.isStarted {
                try server.start()
                setupIntegrations()
            }
        } catch let e {
            print("\n\n\nSERVER ERROR! \(e)\n\n\n")
        }
    }

    fileprivate func setupIntegrations() {
        // proxy api for signing and verification
        let apiProxy = BRAPIProxy(mountAt: "/_api", client: BRAPIClient.sharedClient)
        server.prependMiddleware(middleware: apiProxy)
        
        // http router for native functionality
        let router = BRHTTPRouter()
        server.prependMiddleware(middleware: router)
        
        // basic file server for static assets
        let fileMw = BRHTTPFileMiddleware(baseURL: BRAPIClient.bundleURL(bundleName))
        server.prependMiddleware(middleware: fileMw)
        
        // middleware to always return index.html for any unknown GET request (facilitates window.history style SPAs)
        let indexMw = BRHTTPIndexMiddleware(baseURL: fileMw.baseURL)
        server.prependMiddleware(middleware: indexMw)
        
        // geo plugin provides access to onboard geo location functionality
        router.plugin(BRGeoLocationPlugin())
        
        // camera plugin 
        router.plugin(BRCameraPlugin(fromViewController: self))
        
        // wallet plugin provides access to the wallet
        router.plugin(BRWalletPlugin())
        
        // link plugin which allows opening links to other apps
        router.plugin(BRLinkPlugin(fromViewController: self))
        
        // kvstore plugin provides access to the shared replicated kv store
        router.plugin(BRKVStorePlugin(client: BRAPIClient.sharedClient))
        
        // GET /_close closes the browser modal
        router.get("/_close") { (request, _) -> BRHTTPResponse in
            DispatchQueue.main.async {
                self.closeNow()
            }
            return BRHTTPResponse(request: request, code: 204)
        }
        
        // GET /_didload signals to the presenter that the content successfully loaded
        router.get("/_didload") { (request, _) -> BRHTTPResponse in
            DispatchQueue.main.async {
                self.webviewDidLoad()
            }
            return BRHTTPResponse(request: request, code: 204)
        }
        
        // socket /_webviewinfo will send info about the webview state to client
        router.websocket("/_webviewinfo", client: self)
        
        router.printDebug()
        
        // enable debug if it is turned on
        if let debugUrl = debugEndpoint {
            let url = URL(string: debugUrl)
            fileMw.debugURL = url
            indexMw.debugURL = url
        }
    }
    
    open func preload() {
        _ = self.view // force webview loading
    }
    
    open func refresh() {
        let request = URLRequest(url: indexUrl)
        _ = webView?.load(request)
    }
    
    // MARK: - navigation delegate
    
    open func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let host = url.host, let port = (url as NSURL).port {
            if host == server.listenAddress || port.int32Value == Int32(server.port) {
                return decisionHandler(.allow)
            }
        }
        print("[BRWebViewController disallowing navigation: \(navigationAction)")
        decisionHandler(.cancel)
    }
    
    // MARK: - socket delegate 
    func sendTo(socket: BRWebSocket, data: [String: Any]) {
        do {
            let j = try JSONSerialization.data(withJSONObject: data, options: [])
            if let s = String(data: j, encoding: .utf8) {
                socket.request.queue.async {
                    socket.send(s)
                }
            }
        } catch let e {
            print("LOCATION SOCKET FAILED ENCODE JSON: \(e)")
        }
    }
    
    func sendToAllSockets(data: [String: Any]) {
        for (_, s) in sockets {
            sendTo(socket: s, data: data)
        }
    }
    
    public func socketDidConnect(_ socket: BRWebSocket) {
        print("WEBVIEW SOCKET CONNECT \(socket.id)")
        sockets[socket.id] = socket
        sendTo(socket: socket, data: webViewInfo)
    }
    
    public func socketDidDisconnect(_ socket: BRWebSocket) {
        print("WEBVIEW SOCKET DISCONNECT \(socket.id)")
        sockets.removeValue(forKey: socket.id)
    }
    
    public func socket(_ socket: BRWebSocket, didReceiveText text: String) {
        print("WEBVIEW SOCKET RECV \(text)")
        // this is unused here but just in case just echo received text back
        socket.send(text)
    }
}
