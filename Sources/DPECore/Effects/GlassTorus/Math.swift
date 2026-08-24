import simd

/// Right-handed perspective projection mapping z into Metal's [0, 1] clip range.
func perspectiveMatrix(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let ys = 1 / tan(fovyRadians * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * near, 0)
    ))
}

func translationMatrix(_ t: SIMD3<Float>) -> float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

func rotationMatrix(axis: SIMD3<Float>, angle: Float) -> float4x4 {
    simd_matrix4x4(simd_quatf(angle: angle, axis: normalize(axis)))
}

/// Upper-left 3×3 of a rigid transform — valid as a normal matrix while the
/// model transform stays rotation-only (no non-uniform scale).
func upperLeft3x3(_ m: float4x4) -> float3x3 {
    float3x3(
        SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
        SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
        SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    )
}
