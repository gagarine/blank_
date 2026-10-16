import QuickLookThumbnailing
import CoreGraphics
import OSLog

@objc(BlankThumbnailProvider) final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,_ handler: @escaping (QLThumbnailReply?,Error?) -> Void) {
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let data = try StoredPreview.data(for:request.fileURL)
                guard let provider = CGDataProvider(data:data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at:1) else { throw CocoaError(.fileReadCorruptFile) }
                let bounds = page.getBoxRect(.mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let rotated = abs(page.rotationAngle % 180) == 90
                let natural = rotated ? CGSize(width:bounds.height,height:bounds.width) : bounds.size
                let scale = min(min(1024,request.maximumSize.width)/natural.width,min(1024,request.maximumSize.height)/natural.height)
                let size = CGSize(width:max(1,natural.width*scale),height:max(1,natural.height*scale))
                let rect = CGRect(origin:.zero,size:size)
                let reply = QLThumbnailReply(contextSize:size,drawing:{ context in
                    context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(rect)
                    context.scaleBy(x:scale,y:scale)
                    context.concatenate(page.getDrawingTransform(.mediaBox,rect:CGRect(origin:.zero,size:natural),rotate:0,preserveAspectRatio:true))
                    withExtendedLifetime(pdf) { context.drawPDFPage(page) }; return true
                })
                handler(reply,nil)
            } catch {
                let failure = error as NSError
                Logger(subsystem:"local.blank.quicklook",category:"thumbnail").error("Cached preview failed: \(failure.domain,privacy:.public) \(failure.code,privacy:.public)")
                handler(nil,error)
            }
        }
    }
}
