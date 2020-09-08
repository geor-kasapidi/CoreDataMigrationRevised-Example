import Foundation
import CoreData

enum CoreDataMigrationVersion: String, CaseIterable {
    case version1 = "CoreDataMigration_Example"
    case version2 = "CoreDataMigration_Example 2"
    case version3 = "CoreDataMigration_Example 3"
    case version4 = "CoreDataMigration_Example 4"
}

public enum SQLiteMigrationError: Swift.Error {
    case badStore
    case badVersion(String)
    case noCompatibleVersionFound
    case noMappingModel(from: String, to: String)
}

public struct SQLiteProgressiveMigration {
    public typealias Progress = (Int, Int) -> Void

    struct Step {
        let sourceModel: NSManagedObjectModel
        let destinationModel: NSManagedObjectModel
        let mappingModel: NSMappingModel

        init?(
            sourceModel: NSManagedObjectModel,
            destinationModel: NSManagedObjectModel,
            mappingModelURL: URL?
        ) {
            guard let mappingModel = NSMappingModel(contentsOf: mappingModelURL) ?? (
                try? NSMappingModel.inferredMappingModel(
                    forSourceModel: sourceModel,
                    destinationModel: destinationModel
                )
            )
            else {
                return nil
            }

            self.sourceModel = sourceModel
            self.destinationModel = destinationModel
            self.mappingModel = mappingModel
        }

        func migrate(from sourceURL: URL, to destinationURL: URL) throws {
            try NSMigrationManager(
                sourceModel: self.sourceModel,
                destinationModel: self.destinationModel
            ).migrateStore(
                from: sourceURL,
                sourceType: NSSQLiteStoreType,
                options: nil,
                with: self.mappingModel,
                toDestinationURL: destinationURL,
                destinationType: NSSQLiteStoreType,
                destinationOptions: nil
            )
        }
    }

    let originalStoreURL: URL
    let metadata: [String : Any]
    let currentModel: NSManagedObjectModel
    let bundle: Bundle
    let steps: [Step]

    public init?(
        originalStoreURL: URL,
        bundle: Bundle,
        modelName: String,
        modelVersions: [String],
        mappingModels: [String?]
    ) throws {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: originalStoreURL,
            options: nil
        ) else {
            return nil
        }

        let models: [NSManagedObjectModel] = try modelVersions.map { version in
            if let model = bundle.managedObjectModel(forVersion: version, modelName: modelName) {
                return model
            }
            throw SQLiteMigrationError.badVersion(version)
        }

        guard let currentModelIndex = models.firstIndex(where: {
            $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        }) else {
            throw SQLiteMigrationError.noCompatibleVersionFound
        }

        let modelIndicesToMigrate = models.indices.dropFirst(currentModelIndex)

        let steps = try zip(modelIndicesToMigrate.dropLast(), modelIndicesToMigrate.dropFirst()).map { (i, j) -> Step in
            guard let step = Step(
                sourceModel: models[i],
                destinationModel: models[j],
                mappingModelURL: mappingModels[i].flatMap {
                    bundle.url(forResource: $0, withExtension: "cdm")
                }
            ) else {
                throw SQLiteMigrationError.noMappingModel(
                    from: modelVersions[i],
                    to: modelVersions[j]
                )
            }

            return step
        }

        guard !steps.isEmpty else {
            return nil
        }

        self.originalStoreURL = originalStoreURL
        self.metadata = metadata
        self.currentModel = models[currentModelIndex]
        self.bundle = bundle
        self.steps = steps
    }

    public var stepCount: Int {
        return self.steps.count
    }

    public func performMigration(progress: Progress?) throws {
        let storeCoordinator = NSPersistentStoreCoordinator(
            managedObjectModel: self.currentModel
        )

        try storeCoordinator.checkpointWAL(at: self.originalStoreURL)

        progress?(0, self.steps.count)

        var currentStoreURL = self.originalStoreURL

        for (index, step) in self.steps.enumerated() {
            let newStoreURL = URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ).appendingPathComponent(
                UUID().uuidString
            )

            try step.migrate(
                from: currentStoreURL,
                to: newStoreURL
            )

            if currentStoreURL != self.originalStoreURL {
                try storeCoordinator.destroySQLiteStore(at: currentStoreURL)
            }

            currentStoreURL = newStoreURL

            progress?(index + 1, self.steps.count)
        }

        try storeCoordinator.replaceSQLiteStore(
            at: self.originalStoreURL,
            with: currentStoreURL
        )

        if currentStoreURL != self.originalStoreURL {
            try storeCoordinator.destroySQLiteStore(at: currentStoreURL)
        }
    }
}

private extension NSPersistentStoreCoordinator {
    /// https://developer.apple.com/library/archive/qa/qa1809/_index.html
    /// https://sqlite.org/wal.html
    func checkpointWAL(at url: URL) throws {
        try self.remove(try self.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url,
            options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        ))
    }

    func replaceSQLiteStore(
        at destinationURL: URL,
        with sourceURL: URL
    ) throws {
        try self.replacePersistentStore(
            at: destinationURL,
            destinationOptions: nil,
            withPersistentStoreFrom: sourceURL,
            sourceOptions: nil,
            ofType: NSSQLiteStoreType
        )
    }

    func destroySQLiteStore(at url: URL) throws {
        try self.destroyPersistentStore(
            at: url,
            ofType: NSSQLiteStoreType,
            options: nil
        )
    }
}

extension Bundle {
    public func managedObjectModel(forVersion version: String, modelName: String) -> NSManagedObjectModel? {
        // momd directory contains omo/mom files
        let subdirectory = "\(modelName).momd"

        // optimized model file
        if let omoURL = self.url(
            forResource: version,
            withExtension: "omo",
            subdirectory: subdirectory
        ) {
            return NSManagedObjectModel(contentsOf: omoURL)
        }

        // standard model file
        if let momURL = self.url(
            forResource: version,
            withExtension: "mom",
            subdirectory: subdirectory
        ) {
            return NSManagedObjectModel(contentsOf: momURL)
        }

        return nil
    }
}

extension NSPersistentContainer {
    public func prepareForManualSQLiteMigration() throws -> URL {
        guard let storeDescription = self.persistentStoreDescriptions.first,
              storeDescription.type == NSSQLiteStoreType,
              let storeURL = storeDescription.url
        else {
            throw SQLiteMigrationError.badStore
        }

        storeDescription.shouldAddStoreAsynchronously = false
        storeDescription.shouldInferMappingModelAutomatically = false
        storeDescription.shouldMigrateStoreAutomatically = false

        return storeURL
    }
}
