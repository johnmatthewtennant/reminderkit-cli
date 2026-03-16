# Unexposed Properties Report

Session: c15d1124-70ee-4610-966c-00e94fd82278

## Currently Exposed Properties (from reminderToDict)

| JSON key      | Selector/Source                     |
|---------------|-------------------------------------|
| title         | titleAsString                       |
| notes         | notesAsString                       |
| completed     | isCompleted                         |
| priority      | priority                            |
| flagged       | flagged                             |
| allDay        | allDay                              |
| isOverdue     | isOverdue                           |
| isRecurrent   | isRecurrent                         |
| id            | objectID                            |
| listID        | listID                              |
| parentID      | parentReminderID                    |
| dueDate       | dueDateComponents                   |
| startDate     | startDateComponents                 |
| createdAt     | creationDate                        |
| modifiedAt    | lastModifiedDate                    |
| completedAt   | completionDate                      |
| hashtags      | hashtagContext -> hashtags (labels)  |
| timeZone      | timeZone                            |
| url           | attachmentContext -> urlAttachments  |
| subtasks      | subtaskContext -> subtasks           |

## Available But Unexposed Properties on REMReminder

### High Value — Worth Adding

| Property | Type | Why |
|----------|------|-----|
| `recurrenceRules` | NSArray | Recurring reminders are common; users would want to read/set repeat rules |
| `alarms` | NSArray | Alarm/notification settings — core reminder functionality |
| `attachments` (file/image) | NSArray | Only URL attachments are exposed; file and image attachments are ignored |
| `assignments` | NSSet | Shared reminder assignments — important for collaborative lists |
| `displayDate` | REMDisplayDate | The effective date shown in the UI, may differ from dueDate |
| `icsDisplayOrder` | NSUInteger | Sort order within a list — useful for maintaining custom ordering |

### Medium Value — Situationally Useful

| Property | Type | Why |
|----------|------|-----|
| `icsUrl` | NSURL | The iCalendar URL (now separate from the UI URL field). Some workflows use this for CalDAV integration |
| `batchCreationID` | NSUUID | Groups reminders created together; useful for bulk operation tracking |
| `contactHandles` | REMContactRepresentation | Contact info linked to reminder — useful for "message X" or "call Y" reminders |
| `userActivity` | REMUserActivity | Siri/app context that created the reminder |
| `externalIdentifier` | NSString | CalDAV/external system identifier — useful for sync tools |
| `accountID` | REMObjectID | Which account (iCloud, local, Exchange) the reminder belongs to |
| `isUrgentStateEnabledForCurrentUser` | BOOL | Urgent state flag |

### Low Value — Unlikely Needed

| Property | Type | Why |
|----------|------|-----|
| `titleDocumentData` / `notesDocumentData` | NSData | Raw CRDT document data — internal format, titleAsString/notesAsString cover the use case |
| `resolutionTokenMap` / `resolutionTokenMapData` | NSData | Internal conflict resolution data |
| `importedICSData` | NSData | Raw ICS import data |
| `siriFoundInAppsData` | NSData | Siri internal data |
| `siriFoundInAppsUserConfirmation` | long | Internal Siri state |
| `lastBannerPresentationDate` | NSDate | UI notification tracking |
| `daCalendarItemUniqueIdentifier` | NSString | Internal CalDAV identifier |
| `legacyNotificationIdentifier` | NSString | Legacy compat |
| `primaryLocaleInferredFromLastUsedKeyboard` | NSString | Internal locale tracking |
| `alternativeDisplayDateDate_forCalendar` | NSDate | Internal calendar display |
| `daSyncToken` / `daPushKey` | NSString | Sync infrastructure |
| `externalModificationTag` | NSString | Sync etag |
| `minimumSupportedVersion` / `effectiveMinimumSupportedVersion` | long | Version compat |

## Priority Recommendations

1. **recurrenceRules** — Most requested missing feature for automation
2. **alarms** — Core to what reminders do
3. **icsUrl** — Now that it's been removed from the `url` field, re-expose it as `icsUrl` for users who need CalDAV URL access
4. **displayDate** — Useful for sorting/filtering by what the user actually sees
5. **icsDisplayOrder** — Needed for preserving custom sort order in batch operations
6. **attachments (file/image)** — Completeness for attachment handling

<!-- jtennant review: should do all the high priority ones. None of the others yet. But should note that a few medium ones may be useful in the future: contacthandles seems maybe useful, externalIdentifier might be useful for linking to beads or linear. I don't know what isUrgentStateEnabledForCurrentUser is for. batchCreationID might be useful. Save this list into the repo for future reference. Keep the list up to date as we add new properties. -->