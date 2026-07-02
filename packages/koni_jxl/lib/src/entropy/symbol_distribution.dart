import '../io/bit_reader.dart';
import 'hybrid_uint.dart';

/// Mutable ANS decoder state, shared across all distributions of one
/// entropy-coded section.
final class AnsState {
  int _state = 0;
  bool hasState = false;

  int get state => _state;

  set state(int value) {
    _state = value;
    hasState = true;
  }

  void reset() => hasState = false;
}

/// One symbol distribution (prefix-coded or ANS-coded) within an entropy
/// stream.
abstract base class SymbolDistribution {
  /// Hybrid-integer expansion config, attached after construction.
  HybridIntegerConfig? config;

  int logBucketSize = 0;
  int alphabetSize = 0;
  int logAlphabetSize = 0;

  int readSymbol(BitReader reader, AnsState state);
}
