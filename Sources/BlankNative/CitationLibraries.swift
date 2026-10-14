import Foundation
import Combine

struct CitationLibrary: Identifiable {
    var id: String
    var name: String
}

@MainActor final class CitationLibraries: ObservableObject {
    @Published private(set) var libraries = [CitationLibrary(id:"personal",name:"Personal library")]
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var generation = 0
    func load() {
        generation += 1; let current = generation
        loading = true; error = ""
        func page(_ start: Int,_ collected: [CitationLibrary]) {
            ZoteroIntegration.request("users/0/groups?limit=100&start=\(start)") { result in
                let parsed = result.flatMap { data -> Result<([CitationLibrary],Int),Error> in
                    Result {
                        guard let groups = try JSONSerialization.jsonObject(with:data) as? [[String:Any]] else {
                            throw ZoteroIntegration.failure("Zotero did not return a group library list.")
                        }
                        let entries = try groups.map { group -> CitationLibrary in
                            let id = (group["id"] as? NSNumber)?.stringValue ?? group["id"] as? String ?? ""
                            guard id.range(of:"^[0-9]+$",options:.regularExpression) != nil,
                                  let fields = group["data"] as? [String:Any], let name = fields["name"] as? String else {
                                throw ZoteroIntegration.failure("Zotero returned an invalid group library.")
                            }
                            return CitationLibrary(id:"groups/"+id,name:name)
                        }
                        return (entries,groups.count)
                    }
                }
                DispatchQueue.main.async { [weak self = self] in
                    guard let self, self.generation == current else { return }
                    switch parsed {
                    case let .failure(error): self.loading = false; self.error = error.localizedDescription
                    case let .success((entries,count)):
                        let all = collected+entries
                        // Page locally rather than trusting a server-supplied URL.
                        if count == 100 && start < 9900 { page(start+count,all); return }
                        if count >= 100 { self.loading = false; self.error = "Too many Zotero groups. The previous library list is still available."; return }
                        var seen = Set<String>()
                        self.libraries = [CitationLibrary(id:"personal",name:"Personal library")]+all.filter { seen.insert($0.id).inserted }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        self.loading = false
                    }
                }
            }
        }
        page(0,[])
    }
    func cancel() { generation += 1; loading = false }
}
