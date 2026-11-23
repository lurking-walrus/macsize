import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
public enum Treemap {
    /// Lay out `values` inside `rect`, returning one rectangle per value in the
    /// same order as the input. Each rectangle's area is proportional to its
    /// value; non-positive values get an empty rectangle.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        guard rect.width > 0, rect.height > 0 else { return result }

        let order = values.indices
            .filter { values[$0] > 0 }
            .sorted { values[$0] > values[$1] }
        let total = order.reduce(0.0) { $0 + values[$1] }
        guard total > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var row: [Int] = []
        var rowSum = 0.0

        func worst(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
            let sideSquared = side * side
            let sumSquared = sum * sum
            return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
        }

        func layoutRow() {
            guard !row.isEmpty else { return }
            if remaining.width >= remaining.height {
                // Column on the left side.
                let width = remaining.height > 0 ? CGFloat(rowSum) / remaining.height : 0
                var y = remaining.minY
                for index in row {
                    let height = width > 0 ? CGFloat(values[index] * scale) / width : 0
                    result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining.origin.x += width
                remaining.size.width = max(0, remaining.size.width - width)
            } else {
                // Row along the top.
                let height = remaining.width > 0 ? CGFloat(rowSum) / remaining.width : 0
                var x = remaining.minX
                for index in row {
                    let width = height > 0 ? CGFloat(values[index] * scale) / height : 0
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining.origin.y += height
                remaining.size.height = max(0, remaining.size.height - height)
            }
            row.removeAll(keepingCapacity: true)
            rowSum = 0
        }

        var position = 0
        while position < order.count {
            let index = order[position]
            let area = values[index] * scale
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty {
                row.append(index)
                rowSum = area
                position += 1
                continue
            }
            // Row items are in descending order: first is largest, last is smallest.
            let largest = values[row[0]] * scale
            let current = worst(sum: rowSum, largest: largest, smallest: values[row[row.count - 1]] * scale, side: side)
            let candidate = worst(sum: rowSum + area, largest: largest, smallest: area, side: side)
            if candidate <= current {
                row.append(index)
                rowSum += area
                position += 1
            } else {
                layoutRow()
            }
        }
        layoutRow()
        return result
    }
}
