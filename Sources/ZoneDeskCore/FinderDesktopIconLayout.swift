import Foundation

public struct FinderDesktopIconLayout: Equatable, Sendable {
    public static let finderDefault = FinderDesktopIconLayout(
        iconSize: 64,
        gridSpacing: 54,
        textSize: 12
    )

    public var iconSize: Double
    public var gridSpacing: Double
    public var textSize: Double

    public init(iconSize: Double, gridSpacing: Double, textSize: Double) {
        self.iconSize = iconSize
        self.gridSpacing = gridSpacing
        self.textSize = textSize
    }

    public var titleHeight: Double {
        ceil(textSize * 2.4)
    }

    public var cellSize: Double {
        let selectedIconBottomInset = 4.0
        let titleGap = 6.0
        let titleVerticalPadding = 2.0
        let contentHeight = iconSize
            + selectedIconBottomInset
            + titleGap
            + titleHeight
            + titleVerticalPadding
        return max(iconSize + gridSpacing, contentHeight)
    }

    public var edgeInset: Double {
        max(8, gridSpacing / 2)
    }
}
