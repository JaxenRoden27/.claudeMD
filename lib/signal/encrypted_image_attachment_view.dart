import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'signal_message_repository.dart';
import 'signal_models.dart';

class EncryptedImageAttachmentView extends StatefulWidget {
  const EncryptedImageAttachmentView({
    super.key,
    required this.repository,
    required this.payload,
    required this.dark,
    required this.outgoing,
    this.thumbnailWidth = 220,
    this.thumbnailHeight = 170,
  });

  final SignalMessageRepository? repository;
  final SecureImageAttachmentPayload payload;
  final bool dark;
  final bool outgoing;
  final double thumbnailWidth;
  final double thumbnailHeight;

  @override
  State<EncryptedImageAttachmentView> createState() =>
      _EncryptedImageAttachmentViewState();
}

class _EncryptedImageAttachmentViewState
    extends State<EncryptedImageAttachmentView> {
  Future<Uint8List>? _imageFuture;

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant EncryptedImageAttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.attachmentId != widget.payload.attachmentId ||
        oldWidget.repository != widget.repository) {
      _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    final repository = widget.repository;
    if (repository == null) {
      _imageFuture = null;
      return;
    }

    _imageFuture = repository.downloadAndDecryptAttachment(widget.payload);
  }

  void _retry() {
    setState(_scheduleLoad);
  }

  void _openImageDialog(Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 18,
          ),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Center(
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
              ),
              Positioned(
                top: 10,
                right: 10,
                child: IconButton.filledTonal(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _foregroundColor() {
    if (widget.outgoing) {
      return Colors.white;
    }
    return widget.dark ? const Color(0xFFF9FAFB) : const Color(0xFF1F2933);
  }

  @override
  Widget build(BuildContext context) {
    if (_imageFuture == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_not_supported_outlined, color: _foregroundColor()),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Encrypted image unavailable',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: _foregroundColor()),
            ),
          ),
        ],
      );
    }

    return FutureBuilder<Uint8List>(
      future: _imageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: widget.thumbnailWidth,
            height: widget.thumbnailHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.outgoing
                    ? Colors.white.withValues(alpha: 0.16)
                    : widget.dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _foregroundColor(),
                  ),
                ),
              ),
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return InkWell(
            onTap: _retry,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: widget.thumbnailWidth,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: widget.outgoing
                    ? Colors.white.withValues(alpha: 0.14)
                    : widget.dark
                    ? Colors.white.withValues(alpha: 0.07)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.refresh_rounded, color: _foregroundColor()),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Unable to load image. Tap to retry.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _foregroundColor(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final bytes = snapshot.data!;
        return GestureDetector(
          onTap: () => _openImageDialog(bytes),
          child: Hero(
            tag: 'attachment_${widget.payload.attachmentId}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                width: widget.thumbnailWidth,
                height: widget.thumbnailHeight,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ),
        );
      },
    );
  }
}
