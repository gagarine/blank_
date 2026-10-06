import AppKit
import Foundation

// Intercept only Zotero's loopback endpoint; acceptance never needs a live library.
private final class CitationAcceptanceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" && request.url?.port == 23119
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url!); Self.lock.unlock()
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "q" })?.value ?? ""
        let title = query.isEmpty ? "Citation acceptance reference" : "Search result for " + query
        let data = try! JSONSerialization.data(withJSONObject:[["key":"ABCD1234","data":["itemType":"book","title":title,"creators":[["lastName":"Example"]],"date":"2026"]]])
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:query == "offline" ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum NativeCitationAcceptance {
    static func showFixture(controller: DocumentWindow) {
        URLProtocol.registerClass(CitationAcceptanceProtocol.self)
        controller.session.chooseInsertion("citation")
    }
    static func run(controller: DocumentWindow) {
        let session = controller.session
        let original = session.buffer.source
        func check(_ condition: @autoclosure () -> Bool,_ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        func waitForRequest(_ count: Int) {
            let deadline = Date().addingTimeInterval(3)
            while CitationAcceptanceProtocol.requests.count < count && Date() < deadline {
                RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        }
        check(URLProtocol.registerClass(CitationAcceptanceProtocol.self),"Citation acceptance installs isolated Zotero responses")
        defer { session.sheet = nil; URLProtocol.unregisterClass(CitationAcceptanceProtocol.self) }
        session.chooseInsertion("citation")
        waitForRequest(1)
        let requests = CitationAcceptanceProtocol.requests
        check(requests.count == 1,"Opening Citation loads references without pressing Search")
        let url = requests[0]
        let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        check(url.path == "/api/users/0/items/top" && query.first(where:{ $0.name == "q" })?.value == "" && query.first(where:{ $0.name == "limit" })?.value == "40","Initial citation load uses the bounded empty-query personal library search")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        session.chooseInsertion("citation")
        waitForRequest(2)
        check(CitationAcceptanceProtocol.requests.count == 2,"Reopening Citation loads references for the new presentation")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        session.chooseInsertion("link")
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        check(CitationAcceptanceProtocol.requests.count == 2 && session.buffer.source == original,"Other insertion sheets do not fetch Zotero or change source")
        session.sheet = nil
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    }
}
