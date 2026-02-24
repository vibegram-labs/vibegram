import Foundation

final class ChatEngineStore {
  static let shared = ChatEngineStore()

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "vibe.chat.engine.store")
  private let configKey = "vibe.chat.engine.config.v1"
  private let journalKey = "vibe.chat.engine.journal.v1"
  private let maxJournalCount = 300

  private init() {}

  func setConfig(_ payload: [String: Any]) {
    queue.async {
      guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload)
      else { return }
      self.defaults.set(data, forKey: self.configKey)
    }
  }

  func getConfig() -> [String: Any] {
    queue.sync {
      guard let data = defaults.data(forKey: configKey),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return obj
    }
  }

  func appendJournal(_ entry: [String: Any]) {
    queue.async {
      var items = self.loadJournalLocked()
      items.append(entry)
      if items.count > self.maxJournalCount {
        items = Array(items.suffix(self.maxJournalCount))
      }
      self.saveJournalLocked(items)
    }
  }

  func getJournal(limit: Int? = nil) -> [[String: Any]] {
    queue.sync {
      let items = loadJournalLocked()
      if let limit, limit > 0, items.count > limit {
        return Array(items.suffix(limit))
      }
      return items
    }
  }

  func clearJournal() {
    queue.async {
      self.defaults.removeObject(forKey: self.journalKey)
    }
  }

  private func loadJournalLocked() -> [[String: Any]] {
    guard let data = defaults.data(forKey: journalKey),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return obj
  }

  private func saveJournalLocked(_ items: [[String: Any]]) {
    guard JSONSerialization.isValidJSONObject(items),
          let data = try? JSONSerialization.data(withJSONObject: items)
    else { return }
    defaults.set(data, forKey: journalKey)
  }
}

