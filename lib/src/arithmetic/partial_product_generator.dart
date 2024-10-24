// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// partial_product_generator.dart
// Partial Product matrix generation from Booth recoded multiplicand
//
// 2024 May 15
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:math';

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// Store a Signbit as Logic
class SignBit extends Logic {
  /// This is an inverted sign bit
  bool inverted = false;

  /// Construct a sign bit to store
  SignBit(Logic inl, {this.inverted = false}) : super(name: inl.name) {
    this <= inl;
  }
}

/// A [PartialProductArray] is a class that holds a set of partial products
/// for manipulation by [PartialProductGenerator] and [ColumnCompressor].
abstract class PartialProductArray {
  /// Construct a basic List<List<Logic> to hold an array of partial products
  /// as well as a rowShift array to hold the row shifts.
  PartialProductArray();

  /// The actual shift in each row. This value will be modified by the
  /// sign extension routine used when folding in a sign bit from another
  /// row
  final rowShift = <int>[];

  /// Partial Products output. Generated by selector and extended by sign
  /// extension routines
  late final List<List<Logic>> partialProducts;

  /// rows of partial products
  int get rows => partialProducts.length;

  /// Return the actual largest width of all rows
  int maxWidth() {
    var maxW = 0;
    for (var row = 0; row < rows; row++) {
      final entry = partialProducts[row];
      if (entry.length + rowShift[row] > maxW) {
        maxW = entry.length + rowShift[row];
      }
    }
    return maxW;
  }

  /// Return the Logic at the absolute position ([row], [col]).
  Logic getAbsolute(int row, int col) {
    final product = partialProducts[row];
    while (product.length <= col) {
      product.add(Const(0));
    }
    return partialProducts[row][col - rowShift[row]];
  }

  /// Return the List<Logic> at the
  /// absolute position ([row], List<int> [columns].
  List<Logic> getAbsoluteAll(int row, List<int> columns) {
    final product = partialProducts[row];
    final relMax = columns.reduce(max);
    final absMax = relMax - rowShift[row];
    while (product.length <= absMax) {
      product.add(Const(0));
    }
    return [for (final c in columns) partialProducts[row][c - rowShift[row]]];
  }

  /// Set the Logic at absolute position ([row], [col]) to [val].
  void setAbsolute(int row, int col, Logic val) {
    final product = partialProducts[row];
    final i = col - rowShift[row];
    if (product.length > i) {
      product[i] = val;
    } else {
      while (product.length < i) {
        product.add(Const(0));
      }
      partialProducts[row].add(val);
    }
  }

  /// Mux the Logic at absolute position ([row], [col]) conditionally by
  /// [condition] to [val].
  void muxAbsolute(int row, int col, Logic condition, Logic val) {
    final product = partialProducts[row];
    final i = col - rowShift[row];
    if (product.length > i) {
      if (val is SignBit || product[i] is SignBit) {
        var inv = false;
        if (val is SignBit) {
          inv = val.inverted;
        }
        if (product[i] is SignBit) {
          inv = (product[i] as SignBit).inverted;
        }
        product[i] = SignBit(mux(condition, val, product[i]), inverted: inv);
      } else {
        product[i] = mux(condition, val, product[i]);
      }
    } else {
      while (product.length < i) {
        product.add(Const(0));
      }
      partialProducts[row].add(val);
    }
  }

  /// Set the range at absolute position ([row], [col]) to [list].
  void setAbsoluteAll(int row, int col, List<Logic> list) {
    var i = col - rowShift[row];
    final product = partialProducts[row];
    for (final val in list) {
      if (product.length > i) {
        product[i++] = val;
      } else {
        while (product.length < i) {
          product.add(Const(0));
        }
        product.add(val);
        i++;
      }
    }
  }

  /// Mux the range of values into the row starting at absolute position
  ///  ([row], [col]) using [condition] to select the new value
  void muxAbsoluteAll(int row, int col, Logic condition, List<Logic> list) {
    var i = col - rowShift[row];
    final product = partialProducts[row];
    for (final val in list) {
      if (product.length > i) {
        if (val is SignBit || product[i] is SignBit) {
          var inv = false;
          if (val is SignBit) {
            inv = val.inverted;
          }
          if (product[i] is SignBit) {
            inv = (product[i] as SignBit).inverted;
          }
          product[i] = SignBit(mux(condition, val, product[i]), inverted: inv);
        } else {
          product[i] = mux(condition, val, product[i]);
        }
        i++;
      } else {
        while (product.length < i) {
          product.add(Const(0));
        }
        if (val is SignBit) {
          product.add(
              SignBit(mux(condition, val, Const(0)), inverted: val.inverted));
        } else {
          product.add(mux(condition, val, Const(0)));
        }
        i++;
      }
    }
  }

  /// Set a Logic [val] at the absolute position ([row], [col])
  void insertAbsolute(int row, int col, Logic val) =>
      partialProducts[row].insert(col - rowShift[row], val);

  /// Set the values of the row, starting at absolute position ([row], [col])
  /// to the [list] of values
  void insertAbsoluteAll(int row, int col, List<Logic> list) =>
      partialProducts[row].insertAll(col - rowShift[row], list);
}

/// A [PartialProductGenerator] class that generates a set of partial products.
///  Essentially a set of
/// shifted rows of [Logic] addends generated by Booth recoding and
/// manipulated by sign extension, before being compressed
abstract class PartialProductGenerator extends PartialProductArray {
  /// Get the shift increment between neighboring product rows
  int get shift => selector.shift;

  /// The multiplicand term
  Logic get multiplicand => selector.multiplicand;

  /// The multiplier term
  Logic get multiplier => encoder.multiplier;

  /// Encoder for the full multiply operand
  late final MultiplierEncoder encoder;

  /// Selector for the multiplicand which uses the encoder to index into
  /// multiples of the multiplicand and generate partial products
  late final MultiplicandSelector selector;

  /// Operands are signed
  final bool signed;

  /// Used to avoid sign extending more than once
  bool isSignExtended = false;

  /// Construct a [PartialProductGenerator] -- the partial product matrix
  PartialProductGenerator(
      Logic multiplicand, Logic multiplier, RadixEncoder radixEncoder,
      {required this.signed}) {
    encoder = MultiplierEncoder(multiplier, radixEncoder, signed: signed);
    selector =
        MultiplicandSelector(radixEncoder.radix, multiplicand, signed: signed);

    if (multiplicand.width < selector.shift) {
      throw RohdHclException('multiplicand width must be greater than '
          '${selector.shift}');
    }
    if (multiplier.width < (selector.shift + (signed ? 1 : 0))) {
      throw RohdHclException('multiplier width must be greater than '
          '${selector.shift + (signed ? 1 : 0)}');
    }
    _build();
    signExtend();
  }

  /// Perform sign extension (defined in child classes)
  @protected
  void signExtend();

  /// Setup the partial products array (partialProducts and rowShift)
  void _build() {
    partialProducts = <List<Logic>>[];
    for (var row = 0; row < encoder.rows; row++) {
      partialProducts.add(List.generate(
          selector.width, (i) => selector.select(i, encoder.getEncoding(row))));
    }
    for (var row = 0; row < rows; row++) {
      rowShift.add(row * shift);
    }
  }
}

/// A Partial Product Generator with no sign extension
class PartialProductGeneratorNoSignExtension extends PartialProductGenerator {
  /// Construct a basic Partial Product Generator
  PartialProductGeneratorNoSignExtension(
      super.multiplicand, super.multiplier, super.radixEncoder,
      {required super.signed});

  @override
  void signExtend() {}
}

/// A Partial Product Generator using Compact Rectangular Extension
class PartialProductGeneratorCompactRectSignExtension
    extends PartialProductGenerator {
  /// Construct a compact rect sign extending Partial Product Generator
  PartialProductGeneratorCompactRectSignExtension(
      super.multiplicand, super.multiplier, super.radixEncoder,
      {required super.signed});

  void _addStopSignFlip(List<Logic> addend, Logic sign) {
    if (signed) {
      addend.last = ~addend.last;
    } else {
      addend.add(sign);
    }
  }

  void _addStopSign(List<Logic> addend, Logic sign) {
    if (signed) {
      addend.last = sign;
    } else {
      addend.add(sign);
    }
  }

  /// Sign extend the PP array using stop bits without adding a row
  /// This routine works with different widths of multiplicand/multiplier,
  /// an extension of Mohanty, B.K., Choubey designed by
  /// Desmond A. Kirkpatrick
  @override
  void signExtend() {
    if (isSignExtended) {
      throw RohdHclException('Partial Product array already sign-extended');
    }
    isSignExtended = true;

    final lastRow = rows - 1;
    final firstAddend = partialProducts[0];
    final lastAddend = partialProducts[lastRow];

    final firstRowQStart = selector.width - (signed ? 1 : 0);
    final lastRowSignPos = shift * lastRow;

    final align = firstRowQStart - lastRowSignPos;

    final signs = [for (var r = 0; r < rows; r++) encoder.getEncoding(r).sign];

    // Compute propgation info for folding sign bits into main rows
    final propagate =
        List.generate(rows, (i) => List.filled(0, Logic(), growable: true));

    for (var row = 0; row < rows; row++) {
      propagate[row].add(SignBit(signs[row]));
      for (var col = 0; col < 2 * (shift - 1); col++) {
        propagate[row].add(partialProducts[row][col]);
      }
      // Last row has extend sign propagation to Q start
      if (row == lastRow) {
        var col = 2 * (shift - 1);
        while (propagate[lastRow].length <= align) {
          propagate[lastRow].add(SignBit(partialProducts[row][col++]));
        }
      }
      // Now compute the propagation logic
      for (var col = 1; col < propagate[row].length; col++) {
        propagate[row][col] = propagate[row][col] & propagate[row][col - 1];
      }
    }

    // Compute 'm', the prefix of each row to carry the sign of the next row
    final m =
        List.generate(rows, (i) => List.filled(0, Logic(), growable: true));
    for (var row = 0; row < rows; row++) {
      for (var c = 0; c < shift - 1; c++) {
        m[row].add(partialProducts[row][c] ^ propagate[row][c]);
      }
      m[row].addAll(List.filled(shift - 1, Logic()));
    }
    while (m[lastRow].length < align) {
      m[lastRow].add(Logic());
    }
    for (var i = shift - 1; i < m[lastRow].length; i++) {
      m[lastRow][i] =
          lastAddend[i] ^ (i < align ? propagate[lastRow][i] : Const(0));
    }

    final remainders = List.filled(rows, Logic());
    for (var row = 0; row < lastRow; row++) {
      remainders[row] = propagate[row][shift - 1];
    }
    remainders[lastRow] = propagate[lastRow][align > 0 ? align : 0];

    // Merge 'm' into the LSBs of each addend
    for (var row = 0; row < rows; row++) {
      final addend = partialProducts[row];
      if (row > 0) {
        final mLimit = (row == lastRow) ? align : shift - 1;
        for (var i = 0; i < mLimit; i++) {
          addend[i] = m[row][i];
        }
        // Stop bits
        _addStopSignFlip(addend, SignBit(~signs[row], inverted: true));
        addend
          ..insert(0, remainders[row - 1])
          ..addAll(List.filled(shift - 1, Const(1)));
        rowShift[row] -= 1;
      } else {
        // First row
        for (var i = 0; i < shift - 1; i++) {
          firstAddend[i] = m[0][i];
        }
      }
    }

    // Insert the lastRow sign:  Either in firstRow's Q if there is a
    // collision or in another row if it lands beyond the Q sign extension

    final firstSign = signed ? SignBit(firstAddend.last) : SignBit(signs[0]);
    final lastSign = SignBit(remainders[lastRow]);
    // Compute Sign extension MSBs for firstRow
    final qLen = shift + 1;
    final insertSignPos = (align > 0) ? 0 : -align;
    final q = List.filled(min(qLen, insertSignPos), firstSign, growable: true);
    if (insertSignPos < qLen) {
      // At sign insertion position
      q.add(SignBit(firstSign ^ lastSign));
      if (insertSignPos == qLen - 1) {
        q[insertSignPos] = SignBit(~q[insertSignPos], inverted: true);
        q.add(SignBit(~(firstSign | q[insertSignPos]), inverted: true));
      } else {
        q
          ..addAll(List.filled(
              qLen - insertSignPos - 2, SignBit(firstSign & ~lastSign)))
          ..add(SignBit(~(firstSign & ~lastSign), inverted: true));
      }
    }

    if (-align >= q.length) {
      q.last = SignBit(~firstSign, inverted: true);
    }
    _addStopSign(firstAddend, q[0]);
    firstAddend.addAll(q.getRange(1, q.length));

    if (-align >= q.length) {
      final finalCarryRelPos =
          lastRowSignPos - selector.width - shift + (signed ? 1 : 0);
      final finalCarryRow = (finalCarryRelPos / shift).floor();
      final curRowLength =
          partialProducts[finalCarryRow].length + rowShift[finalCarryRow];

      partialProducts[finalCarryRow]
        ..addAll(List.filled(lastRowSignPos - curRowLength, Const(0)))
        ..add(remainders[lastRow]);
    }
    if (shift == 1) {
      lastAddend.add(Const(1));
    }
  }
}
