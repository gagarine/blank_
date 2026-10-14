import Foundation
// Intercept only Zotero's loopback endpoint; acceptance never needs a live library.
final class CitationAcceptanceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls.filter { !$0.path.hasSuffix("/groups") } }
    static var groupRequests: [URL] { lock.lock(); defer { lock.unlock() }; return urls.filter { $0.path.hasSuffix("/groups") } }
    static var groupFixture = "normal"
    static var itemFixtureOffline = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" && request.url?.port == 23119
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url!); Self.lock.unlock()
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "q" })?.value ?? ""
        let title = query.isEmpty ? "Citation acceptance reference" : "Search result for " + query
        let groups = request.url!.path.hasSuffix("/groups")
        if groups {
            let start = Int(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "start" })?.value ?? "0") ?? 0
            let fixture = Self.groupFixture
            let rows: [[String:Any]] = fixture == "empty" ? [] : fixture == "paged" ? (start..<(start == 0 ? 100 : 102)).map { ["id":$0+100,"data":["name":"Group \($0)"]] } : [["id":123,"data":["name":"Research café 日本"]],["id":456,"data":["name":"Second library"]]]
            let data = fixture == "malformed" ? Data("{}".utf8) : try! JSONSerialization.data(withJSONObject:rows)
            let deliver = {
                self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:fixture == "offline" ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
                self.client?.urlProtocol(self,didLoad:data); self.client?.urlProtocolDidFinishLoading(self)
            }
            if fixture == "late" { DispatchQueue.global().asyncAfter(deadline:.now()+0.3,execute:deliver) } else { deliver() }
            return
        }
        let bibliography = request.url?.query?.contains("format=biblatex") == true
        let itemData = try! JSONSerialization.data(withJSONObject:query == "none" ? [] : [["key":"ABCD1234","data":["itemType":"book","title":title,"creators":[["lastName":"Example"]],"date":"2026"]],["key":"EFGH5678","data":["itemType":"book","title":"Second reference","creators":[["lastName":"Other"]],"date":"2025"]]])
        let data = bibliography ? Data("@book{original, author={Example, Jane}, title={Citation acceptance reference}, year={2026}, publisher={Press}}".utf8) : itemData
        let deliver = {
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:query == "offline" || Self.itemFixtureOffline ? 503 : 200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if query == "old" { DispatchQueue.global().asyncAfter(deadline:.now()+0.3,execute:deliver) } else { deliver() }
    }
    override func stopLoading() {}
}
