const std = @import("std");

/// EIP-2537 MSM discount tables, in thousandths, for k = 1..128 point/scalar pairs.
/// Copied from the final EIP-2537 text (cross-checked against revm bls12_381_const.rs).
const G1_DISCOUNT_TABLE = [128]u16{ 1000, 949, 848, 797, 764, 750, 738, 728, 719, 712, 705, 698, 692, 687, 682, 677, 673, 669, 665, 661, 658, 654, 651, 648, 645, 642, 640, 637, 635, 632, 630, 627, 625, 623, 621, 619, 617, 615, 613, 611, 609, 608, 606, 604, 603, 601, 599, 598, 596, 595, 593, 592, 591, 589, 588, 586, 585, 584, 582, 581, 580, 579, 577, 576, 575, 574, 573, 572, 570, 569, 568, 567, 566, 565, 564, 563, 562, 561, 560, 559, 558, 557, 556, 555, 554, 553, 552, 551, 550, 549, 548, 547, 547, 546, 545, 544, 543, 542, 541, 540, 540, 539, 538, 537, 536, 536, 535, 534, 533, 532, 532, 531, 530, 529, 528, 528, 527, 526, 525, 525, 524, 523, 522, 522, 521, 520, 520, 519 };
const G2_DISCOUNT_TABLE = [128]u16{ 1000, 1000, 923, 884, 855, 832, 812, 796, 782, 770, 759, 749, 740, 732, 724, 717, 711, 704, 699, 693, 688, 683, 679, 674, 670, 666, 663, 659, 655, 652, 649, 646, 643, 640, 637, 634, 632, 629, 627, 624, 622, 620, 618, 615, 613, 611, 609, 607, 606, 604, 602, 600, 598, 597, 595, 593, 592, 590, 589, 587, 586, 584, 583, 582, 580, 579, 578, 576, 575, 574, 573, 571, 570, 569, 568, 567, 566, 565, 563, 562, 561, 560, 559, 558, 557, 556, 555, 554, 553, 552, 552, 551, 550, 549, 548, 547, 546, 545, 545, 544, 543, 542, 541, 541, 540, 539, 538, 537, 537, 536, 535, 535, 534, 533, 532, 532, 531, 530, 530, 529, 528, 528, 527, 526, 526, 525, 524, 524 };

/// EIP-2537 MSM multiplier: discounts are expressed in thousandths.
pub const MSM_MULTIPLIER: u64 = 1000;

fn discount(table: *const [128]u16, k: usize) u64 {
    if (k == 0) return 0;
    // For k > 128 the discount stays at the last entry (max_discount).
    return table[@min(k, table.len) - 1];
}

/// G1MSM discount for k pairs (max_discount = 519).
pub fn msmDiscountG1(k: usize) u64 {
    return discount(&G1_DISCOUNT_TABLE, k);
}

/// G2MSM discount for k pairs (max_discount = 524).
pub fn msmDiscountG2(k: usize) u64 {
    return discount(&G2_DISCOUNT_TABLE, k);
}

/// EIP-2537 MSM gas: k * multiplication_cost * discount(k) // 1000. Returns 0 for k == 0
/// (the precompile itself must reject empty input). Saturates instead of overflowing.
pub fn msmGas(k: usize, multiplication_cost: u64, discount_k: u64) u64 {
    if (k == 0) return 0;
    const k64: u64 = std.math.cast(u64, k) orelse return std.math.maxInt(u64);
    const scaled = std.math.mul(u64, k64, multiplication_cost) catch return std.math.maxInt(u64);
    const total = std.math.mul(u64, scaled, discount_k) catch return std.math.maxInt(u64);
    return total / MSM_MULTIPLIER;
}

test "msmDiscountG1 - EIP-2537 table entries and cap" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 0), msmDiscountG1(0));
    try testing.expectEqual(@as(u64, 1000), msmDiscountG1(1));
    try testing.expectEqual(@as(u64, 949), msmDiscountG1(2));
    try testing.expectEqual(@as(u64, 848), msmDiscountG1(3));
    try testing.expectEqual(@as(u64, 797), msmDiscountG1(4));
    try testing.expectEqual(@as(u64, 728), msmDiscountG1(8));
    try testing.expectEqual(@as(u64, 677), msmDiscountG1(16));
    try testing.expectEqual(@as(u64, 627), msmDiscountG1(32));
    try testing.expectEqual(@as(u64, 576), msmDiscountG1(64));
    try testing.expectEqual(@as(u64, 519), msmDiscountG1(128));
    try testing.expectEqual(@as(u64, 519), msmDiscountG1(129));
    try testing.expectEqual(@as(u64, 519), msmDiscountG1(10_000));
}

test "msmDiscountG2 - EIP-2537 table entries and cap" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 0), msmDiscountG2(0));
    try testing.expectEqual(@as(u64, 1000), msmDiscountG2(1));
    try testing.expectEqual(@as(u64, 1000), msmDiscountG2(2));
    try testing.expectEqual(@as(u64, 923), msmDiscountG2(3));
    try testing.expectEqual(@as(u64, 884), msmDiscountG2(4));
    try testing.expectEqual(@as(u64, 796), msmDiscountG2(8));
    try testing.expectEqual(@as(u64, 717), msmDiscountG2(16));
    try testing.expectEqual(@as(u64, 646), msmDiscountG2(32));
    try testing.expectEqual(@as(u64, 582), msmDiscountG2(64));
    try testing.expectEqual(@as(u64, 524), msmDiscountG2(128));
    try testing.expectEqual(@as(u64, 524), msmDiscountG2(129));
}

test "msmGas - EIP-2537 formula" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 0), msmGas(0, 12000, msmDiscountG1(0)));
    try testing.expectEqual(@as(u64, 12000), msmGas(1, 12000, msmDiscountG1(1)));
    try testing.expectEqual(@as(u64, 22776), msmGas(2, 12000, msmDiscountG1(2)));
    try testing.expectEqual(@as(u64, 22500), msmGas(1, 22500, msmDiscountG2(1)));
    try testing.expectEqual(@as(u64, 45000), msmGas(2, 22500, msmDiscountG2(2)));
    try testing.expectEqual(@as(u64, 128 * 12000 * 519 / 1000), msmGas(128, 12000, msmDiscountG1(128)));
    try testing.expectEqual(std.math.maxInt(u64), msmGas(std.math.maxInt(usize), 12000, 519));
}
