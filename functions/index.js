'use strict';

const admin = require('firebase-admin');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { logger } = require('firebase-functions');

admin.initializeApp();

const RETRYABLE_FCM_CODES = new Set([
  'messaging/internal-error',
  'messaging/server-unavailable',
  'messaging/unknown-error',
  'messaging/message-rate-exceeded',
]);

function extractFcmErrorCode(error) {
  if (!error) {
    return '';
  }

  if (typeof error.code === 'string' && error.code.length > 0) {
    return error.code;
  }

  if (
    error.errorInfo &&
    typeof error.errorInfo.code === 'string' &&
    error.errorInfo.code.length > 0
  ) {
    return error.errorInfo.code;
  }

  return '';
}

function isRetryableFcmError(error) {
  const code = extractFcmErrorCode(error);
  return RETRYABLE_FCM_CODES.has(code);
}

function isInvalidTokenError(error) {
  const code = extractFcmErrorCode(error);
  return (
    code === 'messaging/registration-token-not-registered' ||
    code === 'messaging/invalid-registration-token'
  );
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sendWithRetry(payload, maxAttempts = 3) {
  let attempt = 0;
  let lastError;

  while (attempt < maxAttempts) {
    attempt += 1;
    try {
      await admin.messaging().send(payload);
      return { attempt };
    } catch (error) {
      lastError = error;
      if (!isRetryableFcmError(error) || attempt >= maxAttempts) {
        break;
      }
      await delay(250 * 2 ** attempt);
    }
  }

  throw lastError;
}

exports.sendWakeSignalOnDeviceMessage = onDocumentCreated(
  {
    document: 'conversations/{conversationId}/device_messages/{deliveryId}',
    region: 'us-central1',
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }

    const message = snapshot.data();
    if (!message) {
      return;
    }

    const conversationId = event.params.conversationId;
    const deliveryId = event.params.deliveryId;
    const senderUserId = message.senderUserId;
    const messageType = message.messageType;
    const recipientUserId = message.recipientUserId;
    const recipientDeviceId = message.recipientDeviceId;

    if (!recipientUserId || !recipientDeviceId) {
      logger.warn('Missing routing target on device message', {
        conversationId,
        deliveryId,
      });
      return;
    }

    if (senderUserId && recipientUserId === senderUserId) {
      logger.info('Skipping self-notification for sender device message', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
      });
      return;
    }

    const routingRef = admin
      .firestore()
      .collection('users_private')
      .doc(recipientUserId)
      .collection('device_routing')
      .doc(recipientDeviceId);

    logger.info('Resolving recipient routing token', {
      conversationId,
      deliveryId,
      recipientUserId,
      recipientDeviceId,
    });

    let routingSnap;
    try {
      routingSnap = await routingRef.get();
    } catch (error) {
      logger.error('Failed to read recipient routing document', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
        error: String(error),
      });
      return;
    }

    if (!routingSnap.exists) {
      logger.info('Recipient routing document not found', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
      });
      return;
    }

    const routing = routingSnap.data();
    const token = routing && routing.fcmToken;

    if (!token) {
      logger.info('No FCM token registered for recipient device', {
        conversationId,
        recipientUserId,
        recipientDeviceId,
        deliveryId,
      });
      return;
    }

    const payload = {
      token,
      data: {
        type: 'new_message',
        conversationId,
        deliveryId,
        senderUserId: senderUserId || '',
        messageType: messageType || 'text',
        recipientUserId,
        recipientDeviceId,
      },
      android: {
        priority: 'high',
      },
      apns: {
        headers: {
          'apns-priority': '10',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    };

    try {
      const result = await sendWithRetry(payload);
      logger.info('Wake signal sent', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
        attempt: result.attempt,
      });
    } catch (error) {
      if (isInvalidTokenError(error)) {
        try {
          await routingRef.delete();
          logger.info('Removed stale routing token after send failure', {
            conversationId,
            deliveryId,
            recipientUserId,
            recipientDeviceId,
          });
        } catch (deleteError) {
          logger.warn('Failed to remove stale routing token', {
            conversationId,
            deliveryId,
            recipientUserId,
            recipientDeviceId,
            error: String(deleteError),
          });
        }
      }

      logger.error('Failed to send wake signal', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
        error: String(error),
      });
    }
  },
);

exports.cleanupExpiredAttachments = onSchedule(
  {
    schedule: 'every 24 hours',
    region: 'us-central1',
    timeZone: 'Etc/UTC',
  },
  async () => {
    const now = admin.firestore.Timestamp.now();
    const maxBatchSize = 200;
    const expiredSnap = await admin
      .firestore()
      .collectionGroup('attachments')
      .where('expiresAt', '<=', now)
      .limit(maxBatchSize)
      .get();

    if (expiredSnap.empty) {
      logger.info('No expired attachments found for cleanup');
      return;
    }

    let deletedObjects = 0;
    let deletedDocs = 0;
    let storageErrors = 0;
    const batch = admin.firestore().batch();
    const bucket = admin.storage().bucket();

    for (const doc of expiredSnap.docs) {
      const data = doc.data() || {};
      const storagePath = data.storagePath;

      if (typeof storagePath === 'string' && storagePath.length > 0) {
        try {
          await bucket.file(storagePath).delete({ ignoreNotFound: true });
          deletedObjects += 1;
        } catch (error) {
          storageErrors += 1;
          logger.warn('Failed to delete attachment object', {
            attachmentDocPath: doc.ref.path,
            storagePath,
            error: String(error),
          });
        }
      }

      batch.delete(doc.ref);
      deletedDocs += 1;
    }

    await batch.commit();
    logger.info('Expired attachment cleanup completed', {
      scanned: expiredSnap.size,
      deletedObjects,
      deletedDocs,
      storageErrors,
    });
  },
);
