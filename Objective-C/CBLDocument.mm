//
//  CBLDocument.m
//  CouchbaseLite
//
//  Created by Pasin Suriyentrakorn on 12/29/16.
//  Copyright © 2016 Couchbase. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLDocument.h"
#import "CBLCoreBridge.h"
#import "CBLStringBytes.h"
#import "CBLJSON.h"
#import "CBLInternal.h"
#include "c4Observer.h"


NSString* const kCBLDocumentChangeNotification = @"CBLDocumentChangeNotification";
NSString* const kCBLDocumentSavedNotification = @"CBLDocumentSavedNotification";
NSString* const kCBLDocumentIsExternalUserInfoKey = @"CBLDocumentIsExternalUserInfoKey";


@implementation CBLDocument {
    C4Database* _c4db;
    C4Document* _c4doc;
}

@synthesize documentID=_documentID, database=_database, conflictResolver = _conflictResolver;


- (instancetype) initWithDatabase: (CBLDatabase*)db
                            docID: (NSString*)docID
                        mustExist: (BOOL)mustExist
                            error: (NSError**)outError {
    self = [super init];
    if (self) {
        _database = db;
        _documentID = docID;
        _c4db = db.c4db;
        if (![self loadDoc: outError mustExist: mustExist])
            return nil;
    }
    return self;
}


- (void) dealloc {
    c4doc_free(_c4doc);
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@]", self.class, _documentID];
}


- (BOOL) exists {
    return (_c4doc->flags & kExists) != 0;
}


- (BOOL) isDeleted {
    return (_c4doc->flags & kDeleted) != 0;
}


- (uint64_t) sequence {
    return _c4doc->sequence;
}


- (BOOL) save: (NSError**)outError {
    return [self saveWithConflictResolver: [self getConflictResolver] deletion: NO error: outError];
}


- (BOOL) deleteDocument: (NSError**)outError {
    return [self saveWithConflictResolver: [self getConflictResolver] deletion: YES error: outError];
}


- (BOOL) purge: (NSError**)outError {
    if (![self exists])
        return NO;
    
    C4Transaction transaction(_c4db);
    if (!transaction.begin())
        return convertError(transaction.error(),  outError);
    
    C4Error err;
    if (c4doc_purgeRevision(_c4doc, C4Slice(), &err) >= 0) {
        if (c4doc_save(_c4doc, 0, &err)) {
            // Save succeeded; now commit:
            if (!transaction.commit()) {
                return convertError(transaction.error(), outError);
            }
            
            // Reload:
            if (![self loadDoc: outError mustExist: NO])
                return NO;
            
            [self resetChanges];
            return YES;
        }
    }
    return convertError(err, outError);
}


- (void) revert {
    [self resetChanges];
}


#pragma mark - CBLProperties


- (FLSharedKeys) sharedKeys {
    return c4db_getFLSharedKeys(_c4db);
}


- (void) setHasChanges: (BOOL)hasChanges {
    if (self.hasChanges != hasChanges) {
        [super setHasChanges: hasChanges];
        [_database document: self hasUnsavedChanges: hasChanges];
    }
}


- (void)setObject:(id)value forKeyedSubscript:(NSString *)key {
    [super setObject:value forKeyedSubscript:key];
    [self noteChanged];
}


- (void)setProperties:(NSDictionary *)properties {
    [super setProperties:properties];
    [self noteChanged];
}


#pragma mark - INTERNAL


- (void)changedExternally {
    // The current API design decision is that when a document has unsaved changes, it should
    // not update with external changes and should not post notifications. Instead the conflict
    // resolution will happen when the app saves the document.

    if(!self.hasChanges) {
        [self loadDoc:nil mustExist:YES];
        [self postChangedNotificationExternal:YES];
    }
}


#pragma mark - PRIVATE


- (void)noteChanged {
    self.hasChanges = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName: kCBLDocumentChangeNotification
                                                        object: self];
}


- (void)postChangedNotificationExternal:(BOOL)external {
    NSDictionary* userInfo = external ? @{kCBLDocumentIsExternalUserInfoKey: @YES} : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName: kCBLDocumentSavedNotification
                                                        object: self
                                                      userInfo: userInfo];
}


- (BOOL) loadDoc: (NSError**)outError mustExist: (BOOL)mustExist {
    auto doc = [self readC4Doc: outError mustExist: mustExist];
    if (!doc)
        return NO;
    [self setC4Doc: doc];
    return YES;
}


- (C4Document*) readC4Doc: (NSError**)outError mustExist: (BOOL)mustExist {
    CBLStringBytes docId(_documentID);
    C4Error err;
    auto doc = c4doc_get(_c4db, docId, mustExist, &err);
    if (!doc)
        convertError(err, outError);
    return doc;
}


- (void) setC4Doc: (nullable C4Document*)doc {
    c4doc_free(_c4doc);
    _c4doc = doc;
    [self setRootDict: nullptr orProperties: nil];
    if (_c4doc) {
        C4Slice body = _c4doc->selectedRev.body;
        if (body.size > 0) {
            FLDict root = FLValue_AsDict(FLValue_FromTrustedData({body.buf, body.size}));
            [self setRootDict: root orProperties: nil];
        }
    }
}

- (id<CBLConflictResolver>)getConflictResolver {
    if(_conflictResolver) {
        return _conflictResolver;
    }
    
    return [self.database conflictResolver];
}

- (BOOL)save:(NSDictionary *)propertiesToSave into:(C4Document **)outDoc asDelete:(BOOL)deletion error:(NSError **)error {
    // Encode _properties to data:
    CBLStringBytes docTypeSlice;
    C4DocPutRequest put = {
        .docID = _c4doc->docID,
        .history = &_c4doc->revID,
        .historyCount = 1,
        .save = true,
    };
    if (deletion)
        put.revFlags = kDeleted;
    if (propertiesToSave.count > 0) {
        auto enc = c4db_createFleeceEncoder(_c4db);
        FLEncoder_WriteNSObject(enc, propertiesToSave);
        FLError flErr;
        auto body = FLEncoder_Finish(enc, &flErr);
        FLEncoder_Free(enc);
        if (!body.buf) {
            *outDoc = nullptr;
            return convertError(flErr, error);
        }
        
        put.body = {body.buf, body.size};
        docTypeSlice = self[@"type"];
        put.docType = docTypeSlice;
    }
    
    // Save to database:
    C4Error err;
    C4Document* newDoc = c4doc_put(_c4db, &put, nullptr, &err);
    c4slice_free(put.body);
    
    if (!newDoc && err.code != kC4ErrorConflict) {
        *outDoc = nullptr;
        return convertError(err, error);
    }
    
    *outDoc = newDoc;
    return YES;
}


- (BOOL) saveWithConflictResolver: (id<CBLConflictResolver>)resolver
                         deletion: (bool)deletion
                            error: (NSError**)outError
{
    if (!self.hasChanges && !deletion && [self exists])
        return YES;
    
    C4Transaction transaction(_c4db);
    if (!transaction.begin())
        return convertError(transaction.error(),  outError);
    
    C4Document* newDoc;
    NSDictionary* propertiesToSave = deletion ? nil : self.properties;
    if(![self save:propertiesToSave into:&newDoc asDelete:deletion error:outError]) {
        return NO;
    }

    if(!newDoc && !deletion) {
        C4Error err;
        C4Document *currentDoc = c4doc_get(_c4db, _c4doc->docID, true, &err);
        FLValue currentRoot = FLValue_FromTrustedData({currentDoc->selectedRev.body.buf, currentDoc->selectedRev.body.size});
        NSDictionary *source = FLValue_GetNSObject(currentRoot, [self sharedKeys], nil);
        NSDictionary *resolved = [resolver resolveSource:source withTarget:propertiesToSave andBase:self.savedProperties];
        _c4doc = currentDoc;
        if(![self save:resolved into:&newDoc asDelete:deletion error:outError]) {
            return NO;
        }
        
        [self resetChanges];
    }
    
    // Save succeeded; now commit:
    if (!transaction.commit()) {
        c4doc_free(newDoc);
        return convertError(transaction.error(), outError);
    }
    
    [self setC4Doc: newDoc];
    [self postChangedNotificationExternal:NO];
    if (deletion)
        [self resetChanges];
    
    self.hasChanges = NO;
    return YES;
}


@end

// TODO:
// * Rollback _c4doc if the transaction is aborted.
// * Post document change notification
// * Conflict resolution
