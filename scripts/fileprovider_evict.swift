// fileprovider_evict.swift — per-path FileProvider helper for evict_fileprovider.sh.
// Usage: fileprovider_evict probe|evict   (NUL-separated paths on stdin)
// Output, one line per path: <STATUS>\t<path>
//   probe: READY | SKIP:not_ubiquitous | SKIP:not_uploaded | SKIP:uploading | SKIP:upload_error | ERR:<msg>
//   evict: EVICTED | ERR:<msg>
// "READY" means the provider reports the item uploaded, not uploading and error-free,
// i.e. the cloud copy is current and a local eviction cannot lose data.
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard mode == "probe" || mode == "evict" else {
    FileHandle.standardError.write("usage: fileprovider_evict probe|evict\n".data(using: .utf8)!)
    exit(2)
}
let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                 .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
func clean(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ") }

let input = FileHandle.standardInput.readDataToEndOfFile()
for chunk in input.split(separator: 0, omittingEmptySubsequences: true) {
    guard let path = String(data: chunk, encoding: .utf8) else { continue }
    let url = URL(fileURLWithPath: path)
    var status: String
    if mode == "probe" {
        do {
            let v = try url.resourceValues(forKeys: keys)
            if v.isUbiquitousItem != true { status = "SKIP:not_ubiquitous" }
            else if v.ubiquitousItemUploadingError != nil { status = "SKIP:upload_error" }
            else if v.ubiquitousItemIsUploading == true { status = "SKIP:uploading" }
            else if v.ubiquitousItemIsUploaded != true { status = "SKIP:not_uploaded" }
            else { status = "READY" }
        } catch { status = "ERR:" + clean("\(error)") }
    } else {
        do { try FileManager.default.evictUbiquitousItem(at: url); status = "EVICTED" }
        catch { status = "ERR:" + clean("\(error)") }
    }
    print("\(status)\t\(path)")
}
