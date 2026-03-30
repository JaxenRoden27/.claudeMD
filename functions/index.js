'use strict';

const admin = require('firebase-admin');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { logger } = require('firebase-functions');

admin.initializeApp();

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
    const recipientUserId = message.recipientUserId;
    const recipientDeviceId = message.recipientDeviceId;

    if (!recipientUserId || !recipientDeviceId) {
      logger.warn('Missing routing target on device message', {
        conversationId,
        deliveryId,
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
      await admin.messaging().send(payload);
      logger.info('Wake signal sent', {
        conversationId,
        deliveryId,
        recipientUserId,
        recipientDeviceId,
      });
    } catch (error) {
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
