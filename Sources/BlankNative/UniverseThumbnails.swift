import AppKit
import ImageIO

@MainActor final class UniverseThumbnails: ObservableObject {
    typealias Fetch = (URL,@escaping (Result<Data,Error>) -> Void) -> (() -> Void)
    @Published private(set) var generation = 0
    private let images = NSCache<NSString,NSImage>()
    private var visible = Set<String>()
    private let failed = NSCache<NSString,NSDate>()
    private var requests: [String:(token:UUID,cancel:() -> Void)] = [:]
    private let fetch: Fetch
    private let session: URLSession?
    private let decode = DispatchQueue(label:"blank.universe.thumbnails",qos:.utility)
    init(fetch: Fetch? = nil) {
        failed.countLimit = 128
        images.countLimit = 128; images.totalCostLimit = 12*1024*1024
        if let fetch { self.fetch = fetch; session = nil }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpMaximumConnectionsPerHost = 4
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration:configuration); self.session = session
            self.fetch = { url,complete in
                let task = session.dataTask(with:url) { data,response,error in
                    if let error { complete(.failure(error)); return }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          let data, data.count <= 4*1024*1024 else {
                        complete(.failure(NSError(domain:"Universe thumbnail",code:1))); return
                    }
                    complete(.success(data))
                }
                task.resume(); return { task.cancel() }
            }
        }
    }
    deinit { session?.invalidateAndCancel() }
    func image(_ item: UniverseTemplate) -> NSImage? { images.object(forKey:item.id as NSString) }
    func show(_ item: UniverseTemplate) {
        visible.insert(item.id)
        guard let url = item.thumbnailURL, image(item) == nil, requests[item.id] == nil, failed.object(forKey:item.id as NSString).map({ Date().timeIntervalSince($0 as Date) < 300 }) != true else { return }
        let token = UUID(); requests[item.id] = (token,{})
        let cancel = fetch(url) { [weak self] response in
            guard let self else { return }
            decode.async { [self] in
                let image = (try? response.get()).flatMap(Self.decodeImage)
                DispatchQueue.main.async { [weak self = self] in
                    guard let self, requests[item.id]?.token == token else { return }
                    requests.removeValue(forKey:item.id)
                    if let image, visible.contains(item.id) {
                        images.setObject(image,forKey:item.id as NSString,cost:Int(image.size.width*image.size.height)*4)
                    } else { failed.setObject(Date() as NSDate,forKey:item.id as NSString) }
                    generation += 1
                }
            }
        }
        if requests[item.id]?.token == token { requests[item.id]?.cancel = cancel }
    }
    func hide(_ item: UniverseTemplate) {
        visible.remove(item.id); requests.removeValue(forKey:item.id)?.cancel()
    }
    func cancelAll() {
        requests.values.forEach { $0.cancel() }; requests.removeAll(); visible.removeAll()
    }
    nonisolated private static func decodeImage(_ data: Data) -> NSImage? {
        guard data.count <= 4*1024*1024,
              let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:160,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
    }
}
