import XCTest
@testable import Haya

final class EmbeddingMathTests: XCTestCase {

    // MARK: - Cosine Similarity

    func testCosineSimilarityIdentical() {
        let v: [Float] = [1, 2, 3, 4, 5]
        let sim = EmbeddingMath.cosineSimilarity(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOpposite() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityEmpty() {
        let sim = EmbeddingMath.cosineSimilarity([], [])
        XCTAssertEqual(sim, 0)
    }

    func testCosineSimilarityMismatchedLength() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0)
    }

    // MARK: - L2 Normalize

    func testL2NormalizeUnit() {
        var v: [Float] = [3, 4]
        EmbeddingMath.l2Normalize(&v)
        let magnitude = sqrt(v[0] * v[0] + v[1] * v[1])
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5)
    }

    func testL2NormalizeZeroVector() {
        var v: [Float] = [0, 0, 0]
        EmbeddingMath.l2Normalize(&v)
        XCTAssertEqual(v, [0, 0, 0])
    }

    // MARK: - Compute Centroid

    func testComputeCentroidSingle() {
        let embedding: [Float] = [3, 4]
        let centroid = EmbeddingMath.computeCentroid([embedding])
        XCTAssertNotNil(centroid)
        // Single embedding normalized: [3/5, 4/5] = [0.6, 0.8]
        let magnitude = sqrt(centroid![0] * centroid![0] + centroid![1] * centroid![1])
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5)
    }

    func testComputeCentroidMultiple() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let centroid = EmbeddingMath.computeCentroid([a, b])
        XCTAssertNotNil(centroid)
        // Average of [1,0] and [0,1] = [0.5, 0.5], normalized = [0.707, 0.707]
        let magnitude = sqrt(centroid![0] * centroid![0] + centroid![1] * centroid![1])
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5)
        XCTAssertEqual(centroid![0], centroid![1], accuracy: 1e-5)
    }

    func testComputeCentroidEmpty() {
        let centroid = EmbeddingMath.computeCentroid([])
        XCTAssertNil(centroid)
    }

    // MARK: - Best Match

    func testBestMatchFindsClosest() {
        let query: [Float] = [1, 0, 0]
        let centroids: [(id: String, embedding: [Float])] = [
            (id: "A", embedding: [0, 1, 0]),
            (id: "B", embedding: [0.9, 0.1, 0]),
            (id: "C", embedding: [0, 0, 1]),
        ]
        let result = EmbeddingMath.bestMatch(query: query, centroids: centroids)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.id, "B")
    }

    func testBestMatchEmpty() {
        let query: [Float] = [1, 0]
        let result = EmbeddingMath.bestMatch(query: query, centroids: [])
        XCTAssertNil(result)
    }
}
