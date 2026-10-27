import CGgml
import Testing

struct TensorShapeTests {
    @Test func permutationPreservesDimensionsAndStridesBeyondInt32() throws {
        // Metadata only: the tensor describes a wide row without allocating its audio/model storage.
        let context = try #require(
            ggml_init(ggml_init_params(mem_size: 1024 * 1024, mem_buffer: nil, no_alloc: true)))
        defer { ggml_free(context) }

        let width = Int64(Int32.max) + 8
        let source = try #require(ggml_new_tensor_2d(context, GGML_TYPE_F32, width, 2))
        let result = try #require(ggml_permute(context, source, 1, 0, 2, 3))

        #expect(result.pointee.ne.0 == 2)
        #expect(result.pointee.ne.1 == width)
        #expect(result.pointee.nb.0 == Int(width) * MemoryLayout<Float>.size)
        #expect(result.pointee.nb.1 == MemoryLayout<Float>.size)
    }
}
