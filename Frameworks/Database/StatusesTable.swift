//
//  StatusesTable.swift
//  Evergreen
//
//  Created by Brent Simmons on 5/8/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSDatabase
import RSParser
import Data

final class StatusesTable: DatabaseTable {

	let name: String
	let queue: RSDatabaseQueue
	private let cache = ObjectCache<ArticleStatus>(keyPathForID: \ArticleStatus.articleID)

	init(name: String, queue: RSDatabaseQueue) {

		self.name = name
		self.queue = queue
	}

	func markArticles(_ articles: Set<Article>, statusKey: String, flag: Bool) {
		
		assertNoMissingStatuses(articles)
		let statuses = Set(articles.flatMap { $0.status })
		markArticleStatuses(statuses, statusKey: statusKey, flag: flag)
	}

	func attachCachedStatuses(_ articles: Set<Article>) {
		
		articles.forEach { (oneArticle) in
			
			if let cachedStatus = cache[oneArticle.databaseID] {
				oneArticle.status = cachedStatus
			}
			else if let oneArticleStatus = oneArticle.status {
				cache.add(oneArticleStatus)
			}
		}
	}
	
	func ensureStatusesForParsedArticles(_ parsedArticles: [ParsedItem], _ callback: @escaping RSVoidCompletionBlock) {
		
		var articleIDs = Set(parsedArticles.map { $0.articleID })
		articleIDs = articleIDsMissingStatuses(articleIDs)
		if articleIDs.isEmpty {
			callback()
			return
		}
		
		queue.fetch { (database: FMDatabase!) -> Void in
			
			let statuses = self.fetchStatusesForArticleIDs(articleIDs, database: database)
			
			DispatchQueue.main.async {

				self.cache.addObjectsNotCached(Array(statuses))

				let newArticleIDs = self.articleIDsMissingStatuses(articleIDs)
				self.createStatusForNewArticleIDs(newArticleIDs)
				callback()
			}
		}
	}

	func assertNoMissingStatuses(_ articles: Set<Article>) {
		
		for oneArticle in articles {
			if oneArticle.status == nil {
				assertionFailure("All articles must have a status at this point.")
				return
			}
		}
	}
}

private extension StatusesTable {
	
	// MARK: Marking
	
	func markArticleStatuses(_ statuses: Set<ArticleStatus>, statusKey: String, flag: Bool) {
		
		// Ignore the statuses where status.[statusKey] == flag. Update the remainder and save in database.
		
		var articleIDs = Set<String>()
		
		statuses.forEach { (oneStatus) in
			
			if oneStatus.boolStatus(forKey: statusKey) != flag {
				oneStatus.setBoolStatus(flag, forKey: statusKey)
				articleIDs.insert(oneStatus.articleID)
			}
		}
		
		if !articleIDs.isEmpty {
			updateArticleStatusesInDatabase(articleIDs, statusKey: statusKey, flag: flag)
		}
	}

	// MARK: Fetching
	
	func fetchStatusesForArticleIDs(_ articleIDs: Set<String>, database: FMDatabase) -> Set<ArticleStatus> {
		
		if !articleIDs.isEmpty, let resultSet = selectRowsWhere(key: DatabaseKey.articleID, inValues: Array(articleIDs), in: database) {
			return articleStatusesWithResultSet(resultSet)
		}
		
		return Set<ArticleStatus>()
	}

	func articleStatusesWithResultSet(_ resultSet: FMResultSet) -> Set<ArticleStatus> {
		
		var statuses = Set<ArticleStatus>()
		
		while(resultSet.next()) {
			if let oneArticleStatus = ArticleStatus(row: resultSet) {
				statuses.insert(oneArticleStatus)
			}
		}
		
		return statuses
	}
	
	// MARK: Saving
	
	func saveStatuses(_ statuses: Set<ArticleStatus>) {
		
		let statusArray = statuses.map { $0.databaseDictionary() }
		insertRows(statusArray, insertType: .orIgnore)
	}
	
	private func updateArticleStatusesInDatabase(_ articleIDs: Set<String>, statusKey: String, flag: Bool) {

		updateRowsWithValue(NSNumber(value: flag), valueKey: statusKey, whereKey: DatabaseKey.articleID, matches: Array(articleIDs))
	}
	
	// MARK: Creating
	
	func createStatusForNewArticleIDs(_ articleIDs: Set<String>) {

		let now = Date()
		let statuses = articleIDs.map { (oneArticleID) -> ArticleStatus in
			return ArticleStatus(articleID: oneArticleID, read: false, starred: false, userDeleted: false, dateArrived: now)
		}
		cache.addObjectsNotCached(statuses)

		queue.update { (database: FMDatabase!) -> Void in

			let falseValue = NSNumber(value: false)

			articleIDs.forEach { (oneArticleID) in

				let _ = database.executeUpdate("insert or ignore into  statuses (read, articleID, starred, userDeleted, dateArrived) values (?, ?, ?, ?, ?)", withArgumentsIn:[falseValue, oneArticleID as NSString, falseValue, falseValue, now])
			}
		}
	}

	// MARK: Utilities
	
	func articleIDsMissingStatuses(_ articleIDs: Set<String>) -> Set<String> {
		
		return Set(articleIDs.filter { cache[$0] == nil })
	}
}

extension ParsedItem {

	var articleID: String {
		get {
			return "\(feedURL) \(uniqueID)" //Must be same as Article.articleID
		}
	}
}