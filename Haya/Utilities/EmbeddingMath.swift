import Foundation
import Accelerate

/// High-performance embedding operations using Accelerate/vDSP.
enum EmbeddingMath {
    /// Cosine similarity between two vectors. Returns value in [-1, 1].
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        return dot / denom
    }

    /// L2-normalize a vector in place.
    static func l2Normalize(_ vector: inout [Float]) {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        let norm = sqrt(sumSq)
        guard norm > 1e-8 else { return }
        var scale = 1.0 / norm
        vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(vector.count))
    }

    /// Average multiple embeddings into a centroid. Input embeddings are L2-normalized first.
    static func computeCentroid(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first, !first.isEmpty else { return nil }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for var emb in embeddings {
            l2Normalize(&emb)
            vDSP_vadd(sum, 1, emb, 1, &sum, 1, vDSP_Length(dim))
        }
        var scale = 1.0 / Float(embeddings.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(dim))
        l2Normalize(&sum)
        return sum
    }

    /// Find the best match for a query embedding among stored centroids.
    /// Returns (index, similarity) or nil if centroids is empty.
    static func bestMatch(query: [Float], centroids: [(id: String, embedding: [Float])]) -> (id: String, similarity: Float)? {
        guard !centroids.isEmpty else { return nil }
        var bestID = centroids[0].id
        var bestSim: Float = -1
        for centroid in centroids {
            let sim = cosineSimilarity(query, centroid.embedding)
            if sim > bestSim {
                bestSim = sim
                bestID = centroid.id
            }
        }
        return (bestID, bestSim)
    }
}
