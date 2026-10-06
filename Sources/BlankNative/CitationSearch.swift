import Foundation
import Combine

@MainActor final class CitationSearch: ObservableObject {
    @Published private(set) var references: [ZoteroReference] = []
    @Published private(set) var finding = false
    @Published private(set) var error = ""
    private var generation = 0
    private var pending: DispatchWorkItem?
    func search(query: String, library: String, delay: TimeInterval = 0.18) {
        generation += 1; let current = generation
        pending?.cancel(); finding = true; error = ""
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            ZoteroIntegration.search(query:query,library:library) { [weak self] result in
                guard let self, self.generation == current else { return }
                self.finding = false
                switch result {
                case let .success(items): self.references = items
                case let .failure(error): self.error = error.localizedDescription; self.references = []
                }
            }
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    func cancel() { generation += 1; pending?.cancel(); finding = false }
}
