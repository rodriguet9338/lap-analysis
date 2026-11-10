import Foundation

public enum Geo {
    static let earthRadius: Double = 6_371_000

    /// Local east/north metres relative to an origin (equirectangular; fine at track scale).
    /// The origin is the mean latitude/longitude.
    public static func project(latitude: [Double], longitude: [Double]) -> [(x: Double, y: Double)] {
        let n: Int = Swift.min(latitude.count, longitude.count)
        var out: [(x: Double, y: Double)] = []
        if n == 0 { return out }
        var sumLat: Double = 0
        var sumLon: Double = 0
        for i in 0..<n {
            sumLat += latitude[i]
            sumLon += longitude[i]
        }
        let lat0: Double = sumLat / Double(n)
        let lon0: Double = sumLon / Double(n)
        let toRad: Double = Double.pi / 180
        let cosLat0: Double = cos(lat0 * toRad)
        out.reserveCapacity(n)
        for i in 0..<n {
            let x: Double = earthRadius * (longitude[i] - lon0) * toRad * cosLat0
            let y: Double = earthRadius * (latitude[i] - lat0) * toRad
            out.append((x: x, y: y))
        }
        return out
    }

    /// Great-circle distance in metres.
    public static func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let toRad: Double = Double.pi / 180
        let phi1: Double = lat1 * toRad
        let phi2: Double = lat2 * toRad
        let dPhi: Double = (lat2 - lat1) * toRad
        let dLambda: Double = (lon2 - lon1) * toRad
        let sinHalfPhi: Double = sin(dPhi / 2)
        let sinHalfLambda: Double = sin(dLambda / 2)
        let a: Double = sinHalfPhi * sinHalfPhi + cos(phi1) * cos(phi2) * sinHalfLambda * sinHalfLambda
        let c: Double = 2 * atan2(sqrt(a), sqrt(Swift.max(0, 1 - a)))
        return earthRadius * c
    }
}
