import simd

/// One grid sample. A vertex is nothing but its parameter pair — the surface
/// itself is evaluated in the vertex shader, which is what lets the twist
/// animate without rebuilding the mesh every frame.
struct TorusVertex {
    var uv: SIMD2<Float>
}

enum TorusMesh {
    /// A plain (u, v) grid over [0, 2π]². Both wraps get duplicated edge rows
    /// (`0...segments` rather than `0..<segments`) so the seams have their own
    /// vertices and the deformation stays continuous across them.
    ///
    /// Keep `(majorSegments + 1) * (minorSegments + 1)` under 65536 — the index
    /// buffer is UInt16.
    static func make(
        majorSegments: Int,
        minorSegments: Int
    ) -> (vertices: [TorusVertex], indices: [UInt16]) {
        var vertices: [TorusVertex] = []
        vertices.reserveCapacity((majorSegments + 1) * (minorSegments + 1))

        for i in 0...majorSegments {
            let u = Float(i) / Float(majorSegments) * 2 * .pi
            for j in 0...minorSegments {
                let v = Float(j) / Float(minorSegments) * 2 * .pi
                vertices.append(TorusVertex(uv: SIMD2<Float>(u, v)))
            }
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(majorSegments * minorSegments * 6)
        let ringStride = minorSegments + 1
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let a = UInt16(i * ringStride + j)
                let b = UInt16((i + 1) * ringStride + j)
                let c = UInt16((i + 1) * ringStride + j + 1)
                let d = UInt16(i * ringStride + j + 1)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        return (vertices, indices)
    }
}
