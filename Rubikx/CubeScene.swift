import RealityKit
import RubikxCore
import UIKit

/// The cube's RealityKit entities.
///
/// Hierarchy: `anchor` → `cubeRoot` (whole-cube orientation) → one entity per cubie, each with a
/// rounded body and its stickers. While a layer turns, its cubies are moved under a pivot entity
/// in `cubeRoot` and the pivot is rotated. When the turn ends they go back under `cubeRoot`
/// with transforms rebuilt from `CubeState`, so floating-point error never builds up.
@MainActor
final class CubeScene {
    let anchor = AnchorEntity(world: .zero)
    let cubeRoot = Entity()

    private var cubieEntities: [SIMD3<Int>: Entity] = [:]
    private var bodies: [SIMD3<Int>: ModelEntity] = [:]
    private var homeByEntity: [ObjectIdentifier: SIMD3<Int>] = [:]
    private var pivots: [Int: Entity] = [:]
    /// Homes of the cubies in the layer a long-press grips.
    private var gripped: Set<SIMD3<Int>> = []

    private let bodyMaterial = SimpleMaterial(color: UIColor(white: 0.05, alpha: 1), roughness: 0.55, isMetallic: false)
    private let highlightMaterial = SimpleMaterial(color: UIColor(white: 0.2, alpha: 1), roughness: 0.55, isMetallic: false)

    init(state: CubeState) {
        anchor.addChild(cubeRoot)

        let bodyMesh = MeshResource.generateBox(size: 0.96, cornerRadius: 0.1)
        let stickerMesh = MeshResource.generatePlane(width: 0.82, height: 0.82, cornerRadius: 0.12)
        var stickerMaterials: [StickerColor: RealityKit.Material] = [:]
        for color in StickerColor.allCases {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color.uiColor)
            material.roughness = .init(floatLiteral: 0.3)
            material.metallic = .init(floatLiteral: 0)
            material.clearcoat = .init(floatLiteral: 0.4)
            stickerMaterials[color] = material
        }

        for cubie in state.cubies {
            let entity = Entity()
            let body = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
            entity.addChild(body)
            for sticker in cubie.homeStickers {
                let normal = SIMD3<Float>(sticker.normal.vector)
                let plane = ModelEntity(mesh: stickerMesh, materials: [stickerMaterials[sticker.color]!])
                plane.position = normal * 0.483
                plane.orientation = simd_quatf(from: [0, 0, 1], to: normal)
                entity.addChild(plane)
            }
            cubeRoot.addChild(entity)
            cubieEntities[cubie.home] = entity
            bodies[cubie.home] = body
            homeByEntity[ObjectIdentifier(entity)] = cubie.home
        }
        sync(state)
    }

    /// Puts every cubie back under `cubeRoot` exactly where `state` says it is.
    func sync(_ state: CubeState) {
        for pivot in pivots.values { pivot.removeFromParent() }
        pivots = [:]
        for cubie in state.cubies {
            let entity = cubieEntities[cubie.home]!
            entity.setParent(cubeRoot)
            place(entity, cubie)
            bodies[cubie.home]!.model?.materials = [bodyMaterial]
        }
    }

    /// Moves the cubies of one layer under a pivot so the layer can be turned.
    func beginTurn(axis: Axis, layer: Int, state: CubeState) {
        guard pivots[layer] == nil else { return }
        let pivot = Entity()
        cubeRoot.addChild(pivot)
        for cubie in state.cubies(inLayer: layer, of: axis) {
            cubieEntities[cubie.home]!.setParent(pivot, preservingWorldTransform: true)
        }
        pivots[layer] = pivot
    }

    func setAngle(_ angle: Double, axis: Axis, layer: Int) {
        pivots[layer]?.orientation = simd_quatf(angle: Float(angle), axis: SIMD3<Float>(axis.unit))
    }

    func setHighlighted(_ highlighted: Bool, layer: Int) {
        guard let pivot = pivots[layer] else { return }
        for child in pivot.children {
            guard let home = homeByEntity[ObjectIdentifier(child)] else { continue }
            bodies[home]!.model?.materials = [highlighted ? highlightMaterial : bodyMaterial]
        }
    }

    /// Highlights the cubies in one layer, or clears the highlight when `axis` is nil.
    func setGrip(axis: Axis?, layer: Int, state: CubeState) {
        for home in gripped {
            bodies[home]!.model?.materials = [bodyMaterial]
        }
        gripped = []
        guard let axis else { return }
        for cubie in state.cubies(inLayer: layer, of: axis) {
            gripped.insert(cubie.home)
            bodies[cubie.home]!.model?.materials = [highlightMaterial]
        }
    }

    /// Returns a turned layer's cubies to `cubeRoot`. `state` must already include the turn.
    func endTurn(layer: Int, state: CubeState) {
        guard let pivot = pivots.removeValue(forKey: layer) else { return }
        let cubieByHome = Dictionary(uniqueKeysWithValues: state.cubies.map { ($0.home, $0) })
        for child in Array(pivot.children) {
            guard let home = homeByEntity[ObjectIdentifier(child)] else { continue }
            child.setParent(cubeRoot)
            place(child, cubieByHome[home]!)
            bodies[home]!.model?.materials = [bodyMaterial]
        }
        pivot.removeFromParent()
    }

    private func place(_ entity: Entity, _ cubie: Cubie) {
        let m = cubie.orientation.columns
        let rotation = simd_float3x3(columns: (SIMD3<Float>(m.0), SIMD3<Float>(m.1), SIMD3<Float>(m.2)))
        entity.transform = Transform(scale: .one, rotation: simd_quatf(rotation), translation: SIMD3<Float>(cubie.position))
    }
}

extension StickerColor {
    var uiColor: UIColor {
        switch self {
        case .white: UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1)
        case .yellow: UIColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1)
        case .red: UIColor(red: 0.78, green: 0.05, blue: 0.1, alpha: 1)
        case .orange: UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1)
        case .green: UIColor(red: 0.0, green: 0.62, blue: 0.3, alpha: 1)
        case .blue: UIColor(red: 0.0, green: 0.3, blue: 0.85, alpha: 1)
        }
    }
}
