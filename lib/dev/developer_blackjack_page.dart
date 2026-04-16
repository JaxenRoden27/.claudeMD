import 'dart:math';

import 'package:flutter/material.dart';

const _tableGreen = Color(0xFF1E5D34);
const _feltDeep = Color(0xFF174629);
const _cardInk = Color(0xFF1D2A36);

enum _RoundPhase { ready, playerTurn, aiTurns, dealerTurn, settled }

class DeveloperBlackjackPage extends StatefulWidget {
  const DeveloperBlackjackPage({super.key});

  @override
  State<DeveloperBlackjackPage> createState() => _DeveloperBlackjackPageState();
}

class _DeveloperBlackjackPageState extends State<DeveloperBlackjackPage> {
  static const int _startingChips = 200;
  static const int _betAmount = 10;

  final Random _random = Random();
  final List<_PlayingCard> _deck = <_PlayingCard>[];

  late final _TablePlayer _humanPlayer;
  late final List<_TablePlayer> _aiPlayers;
  final _TablePlayer _dealer = _TablePlayer(
    name: 'Dealer',
    chips: 0,
    isHuman: false,
  );

  _RoundPhase _phase = _RoundPhase.ready;
  String _status = 'Tap Deal to start a round.';
  bool _runningAutoTurn = false;

  @override
  void initState() {
    super.initState();
    _humanPlayer = _TablePlayer(
      name: 'You',
      chips: _startingChips,
      isHuman: true,
    );
    _aiPlayers = List<_TablePlayer>.generate(
      3,
      (index) => _TablePlayer(
        name: 'AI ${index + 1}',
        chips: _startingChips,
        isHuman: false,
      ),
    );
    _reshuffleDeck();
  }

  List<_TablePlayer> get _seatedPlayers => <_TablePlayer>[
    _humanPlayer,
    ..._aiPlayers,
  ];

  void _reshuffleDeck() {
    const suits = <String>['H', 'D', 'C', 'S'];
    const ranks = <String>[
      'A',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
      'J',
      'Q',
      'K',
    ];

    _deck
      ..clear()
      ..addAll(
        suits.expand(
          (suit) => ranks.map((rank) => _PlayingCard(rank: rank, suit: suit)),
        ),
      )
      ..shuffle(_random);
  }

  _PlayingCard _drawCard() {
    if (_deck.isEmpty) {
      _reshuffleDeck();
    }
    return _deck.removeLast();
  }

  Future<void> _dealRound() async {
    if (_runningAutoTurn || _phase == _RoundPhase.playerTurn) {
      return;
    }

    if (_deck.length < 24) {
      _reshuffleDeck();
    }

    for (final player in _seatedPlayers) {
      player.resetHand();
    }
    _dealer.resetHand();

    for (var cardIndex = 0; cardIndex < 2; cardIndex++) {
      for (final player in _seatedPlayers) {
        player.hand.add(_drawCard());
      }
      _dealer.hand.add(_drawCard());
    }

    for (final player in _seatedPlayers) {
      player.blackjack = _isBlackjack(player.hand);
      player.busted = _isBust(player.hand);
      player.standing = player.blackjack || player.busted;
    }

    _dealer.blackjack = _isBlackjack(_dealer.hand);
    _dealer.busted = _isBust(_dealer.hand);

    final humanCanAct = !_humanPlayer.blackjack && !_humanPlayer.busted;

    if (!mounted) {
      return;
    }
    setState(() {
      _phase = humanCanAct ? _RoundPhase.playerTurn : _RoundPhase.aiTurns;
      _status = humanCanAct
          ? 'Your move: Hit or Stand.'
          : 'Auto-resolving round...';
    });

    if (!humanCanAct) {
      await _runAutomaticTurns();
    }
  }

  void _hit() {
    if (_phase != _RoundPhase.playerTurn || _runningAutoTurn) {
      return;
    }

    setState(() {
      _humanPlayer.hand.add(_drawCard());
      _humanPlayer.busted = _isBust(_humanPlayer.hand);

      final reachedTwentyOne = _handValue(_humanPlayer.hand) == 21;
      if (_humanPlayer.busted) {
        _humanPlayer.standing = true;
        _phase = _RoundPhase.aiTurns;
        _status = 'You busted. Resolving round...';
      } else if (reachedTwentyOne) {
        _humanPlayer.standing = true;
        _phase = _RoundPhase.aiTurns;
        _status = '21 reached. Resolving round...';
      } else {
        _status = 'Your move: Hit or Stand.';
      }
    });

    if (_phase == _RoundPhase.aiTurns) {
      _runAutomaticTurns();
    }
  }

  void _stand() {
    if (_phase != _RoundPhase.playerTurn || _runningAutoTurn) {
      return;
    }

    setState(() {
      _humanPlayer.standing = true;
      _phase = _RoundPhase.aiTurns;
      _status = 'You stand. AI players are acting...';
    });

    _runAutomaticTurns();
  }

  Future<void> _runAutomaticTurns() async {
    if (_runningAutoTurn) {
      return;
    }

    _runningAutoTurn = true;
    try {
      for (final player in _aiPlayers) {
        if (player.blackjack || player.busted) {
          player.standing = true;
          continue;
        }

        if (!mounted) {
          return;
        }
        setState(() {
          _status = '${player.name} is playing...';
        });

        while (_handValue(player.hand) < 16) {
          await Future<void>.delayed(const Duration(milliseconds: 420));
          if (!mounted) {
            return;
          }
          setState(() {
            player.hand.add(_drawCard());
            player.busted = _isBust(player.hand);
            if (player.busted) {
              player.standing = true;
            }
          });

          if (player.busted) {
            break;
          }
        }

        player.standing = true;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _RoundPhase.dealerTurn;
        _status = 'Dealer is drawing...';
      });

      await Future<void>.delayed(const Duration(milliseconds: 350));
      while (_handValue(_dealer.hand) < 17) {
        await Future<void>.delayed(const Duration(milliseconds: 420));
        if (!mounted) {
          return;
        }
        setState(() {
          _dealer.hand.add(_drawCard());
          _dealer.busted = _isBust(_dealer.hand);
        });
      }

      _settleRound();
    } finally {
      _runningAutoTurn = false;
    }
  }

  void _settleRound() {
    final dealerValue = _handValue(_dealer.hand);
    final dealerBusted = _isBust(_dealer.hand);
    final dealerBlackjack = _isBlackjack(_dealer.hand);

    var winners = 0;
    var losses = 0;
    var pushes = 0;

    for (final player in _seatedPlayers) {
      final playerValue = _handValue(player.hand);
      final playerBusted = _isBust(player.hand);
      final playerBlackjack = _isBlackjack(player.hand);

      player.busted = playerBusted;
      player.blackjack = playerBlackjack;

      if (playerBusted) {
        player.chips -= _betAmount;
        losses++;
        continue;
      }

      if (playerBlackjack && !dealerBlackjack) {
        player.chips += (_betAmount * 1.5).round();
        winners++;
        continue;
      }

      if (dealerBusted) {
        player.chips += _betAmount;
        winners++;
        continue;
      }

      if (dealerBlackjack && !playerBlackjack) {
        player.chips -= _betAmount;
        losses++;
        continue;
      }

      if (playerValue > dealerValue) {
        player.chips += _betAmount;
        winners++;
      } else if (playerValue < dealerValue) {
        player.chips -= _betAmount;
        losses++;
      } else {
        pushes++;
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _phase = _RoundPhase.settled;
      _status = 'Round settled: $winners win, $losses lose, $pushes push.';
    });
  }

  void _resetChips() {
    if (_runningAutoTurn) {
      return;
    }

    setState(() {
      for (final player in _seatedPlayers) {
        player.chips = _startingChips;
        player.resetHand();
      }
      _dealer.resetHand();
      _phase = _RoundPhase.ready;
      _status = 'Chips reset. Tap Deal to start a round.';
    });
  }

  int _handValue(List<_PlayingCard> cards) {
    var total = 0;
    var aces = 0;

    for (final card in cards) {
      total += card.points;
      if (card.rank == 'A') {
        aces++;
      }
    }

    while (total > 21 && aces > 0) {
      total -= 10;
      aces--;
    }

    return total;
  }

  bool _isBust(List<_PlayingCard> cards) => _handValue(cards) > 21;

  bool _isBlackjack(List<_PlayingCard> cards) {
    return cards.length == 2 && _handValue(cards) == 21;
  }

  @override
  Widget build(BuildContext context) {
    final canDeal =
        !_runningAutoTurn &&
        (_phase == _RoundPhase.ready || _phase == _RoundPhase.settled);
    final canPlayHand = !_runningAutoTurn && _phase == _RoundPhase.playerTurn;

    return Scaffold(
      appBar: AppBar(title: const Text('Developer Blackjack Table')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[_feltDeep, _tableGreen],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(
                    _status,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: <Widget>[
                        _SeatPanel(
                          title: 'Dealer',
                          cards: _dealer.hand,
                          valueLabel:
                              _phase == _RoundPhase.playerTurn &&
                                  _dealer.hand.length >= 2
                              ? '?'
                              : _handValue(_dealer.hand).toString(),
                          status: _dealer.blackjack
                              ? 'Blackjack'
                              : _dealer.busted
                              ? 'Busted'
                              : null,
                          hideHoleCard: _phase == _RoundPhase.playerTurn,
                        ),
                        const SizedBox(height: 12),
                        ..._seatedPlayers.map(
                          (player) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _SeatPanel(
                              title: player.name,
                              chipsLabel: 'Chips: ${player.chips}',
                              cards: player.hand,
                              valueLabel: _handValue(player.hand).toString(),
                              status: player.blackjack
                                  ? 'Blackjack'
                                  : player.busted
                                  ? 'Busted'
                                  : player.standing
                                  ? 'Standing'
                                  : player.isHuman &&
                                        _phase == _RoundPhase.playerTurn
                                  ? 'Your turn'
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton(
                        onPressed: canDeal ? _dealRound : null,
                        child: const Text('Deal'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: canPlayHand ? _hit : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                        ),
                        child: const Text('Hit'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: canPlayHand ? _stand : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                        ),
                        child: const Text('Stand'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _runningAutoTurn ? null : _resetChips,
                    child: const Text('Reset Chips'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SeatPanel extends StatelessWidget {
  const _SeatPanel({
    required this.title,
    required this.cards,
    required this.valueLabel,
    this.chipsLabel,
    this.status,
    this.hideHoleCard = false,
  });

  final String title;
  final String? chipsLabel;
  final List<_PlayingCard> cards;
  final String valueLabel;
  final String? status;
  final bool hideHoleCard;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (chipsLabel != null)
                Text(
                  chipsLabel!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: cards.isEmpty
                ? const <Widget>[
                    Text(
                      'No cards yet',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ]
                : List<Widget>.generate(cards.length, (index) {
                    final shouldHide = hideHoleCard && index == 1;
                    return _CardFace(card: cards[index], hidden: shouldHide);
                  }),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text(
                'Value: $valueLabel',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (status != null) ...<Widget>[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    status!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({required this.card, required this.hidden});

  final _PlayingCard card;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final isRed = card.suit == 'H' || card.suit == 'D';

    return Container(
      width: 48,
      height: 70,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: hidden ? _cardInk : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hidden ? Colors.white54 : const Color(0xFFCBD2D9),
        ),
      ),
      child: hidden
          ? const Center(
              child: Icon(Icons.casino_outlined, size: 18, color: Colors.white),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  card.rank,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: isRed ? Colors.red.shade700 : _cardInk,
                  ),
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    card.suit,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isRed ? Colors.red.shade700 : _cardInk,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _TablePlayer {
  _TablePlayer({
    required this.name,
    required this.chips,
    required this.isHuman,
  });

  final String name;
  int chips;
  final bool isHuman;
  final List<_PlayingCard> hand = <_PlayingCard>[];

  bool standing = false;
  bool busted = false;
  bool blackjack = false;

  void resetHand() {
    hand.clear();
    standing = false;
    busted = false;
    blackjack = false;
  }
}

class _PlayingCard {
  const _PlayingCard({required this.rank, required this.suit});

  final String rank;
  final String suit;

  int get points {
    if (rank == 'A') {
      return 11;
    }
    if (rank == 'K' || rank == 'Q' || rank == 'J') {
      return 10;
    }
    return int.parse(rank);
  }
}
