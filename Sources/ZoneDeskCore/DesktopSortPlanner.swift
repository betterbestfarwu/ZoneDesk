import Foundation

public enum DesktopSortPlanner {
    public static func visualSortMoves(
        files: [DesktopFile],
        zones: [ZoneModel],
        options: GridLayoutOptions = GridLayoutOptions(),
        desktopHeight: Double? = nil
    ) -> [VisualSortMove] {
        zones.flatMap { zone in
            let matchingFiles = files
                .filter { zone.acceptedCategories.contains($0.category) }
                .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            let targets: [FinderIconPoint]
            if let desktopHeight {
                let finderRect = finderDesktopRect(for: zone.rect, desktopHeight: desktopHeight)
                targets = GridLayout.topLeftPoints(in: finderRect, itemCount: matchingFiles.count, options: options)
            } else {
                targets = GridLayout.points(in: zone.rect, itemCount: matchingFiles.count, options: options)
            }

            return zip(matchingFiles, targets).map { file, target in
                VisualSortMove(file: file, zone: zone, target: target)
            }
        }
    }

    private static func finderDesktopRect(for rect: ZoneRect, desktopHeight: Double) -> ZoneRect {
        ZoneRect(
            x: rect.x,
            y: desktopHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
