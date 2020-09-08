//
//  CoreDataManager.swift
//  CoreDataMigration-Example
//
//  Created by William Boles on 11/09/2017.
//  Copyright © 2017 William Boles. All rights reserved.
//

import Foundation
import CoreData

class CoreDataManager {
    private let container: NSPersistentContainer

    lazy var backgroundContext: NSManagedObjectContext = {
        let context = self.container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return context
    }()

    lazy var mainContext: NSManagedObjectContext = {
        let context = self.container.viewContext
        context.automaticallyMergesChangesFromParent = true

        return context
    }()

    // MARK: - Singleton
    
    static let shared = CoreDataManager()
    
    // MARK: - Init
    
    init() {
        self.container = NSPersistentContainer(name: "CoreDataMigration_Example")

        do {
            let url = try self.container.prepareForManualSQLiteMigration()

            guard let migration = try SQLiteProgressiveMigration(
                originalStoreURL: url,
                bundle: .main,
                modelName: "CoreDataMigration_Example",
                modelVersions: CoreDataMigrationVersion.allCases.map(\.rawValue),
                mappingModels: [nil, "Migration2to3ModelMapping", nil]
            ) else {
                return
            }

            try migration.performMigration { (currentStep, numberOfSteps) in

            }
        } catch {
            print(error)
        }

        self.container.loadPersistentStores(completionHandler: { _, _ in })
    }
}
