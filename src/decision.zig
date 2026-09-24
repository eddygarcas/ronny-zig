//! Whether a reply the owner has drafted should actually be sent.
//!
//! Port of `_decision` in `ronny/telegram_bot.py`. This is the most
//! load-bearing logic in Ronny and it is kept in its own file, away from the
//! bot plumbing, because getting it wrong sends real mail to a real person.
//!
//! The rules and the reasons they exist:
//!
//! - **Deterministic, never the model.** Approval is plain language ("yes",
//!   "no") but resolved by word matching. If a model could turn "yes" into a
//!   send, a misreading would send mail -- which is the whole thing being
//!   guarded against. There is deliberately no send action in the intent
//!   vocabulary either.
//!
//! - **Negation is checked first**, so "dont send it" cancels rather than
//!   matching on "send".
//!
//! - **Polarity words are separate from filler**, so "do it" reads as yes and
//!   "don't do it" as no. An earlier fixed-phrase list missed "ok go ahead",
//!   which fell through to the classifier and silently re-drafted the pending
//!   reply -- meaning the owner could have confirmed a body they never read.
//!
//! - **Ambiguity never sends.** An unclear answer leaves the draft pending and
//!   asks. Guessing wrong toward sending is irreversible and reaches someone
//!   else; guessing wrong toward asking costs one word.

const std = @import("std");

pub const Decision = enum { confirm, cancel, unclear };

/// Longer than this is prose, not an answer.
pub const MAX_WORDS = 5;

const YES_WORDS = [_][]const u8{
    "yes",     "y",       "yeah",     "yep",   "yup",   "ok",    "okay",
    "k",       "sure",    "send",     "go",    "ahead", "do",    "confirm",
    "confirmed", "approve", "approved", "agreed", "perfect", "correct",
    "proceed", "great",
    // Spanish: the owner switches language mid-conversation.
    "si",      "sí",      "vale",     "dale",  "adelante", "envia", "envialo",
    "enviar",
};

const NO_WORDS = [_][]const u8{
    "no",    "nope",   "nah",      "n",      "not",    "cancel", "stop",
    "dont",  "discard", "abort",   "never",  "scrap",  "forget", "nevermind",
    "wait",  "hold",
    "nada",  "cancela", "cancelar", "olvida", "espera", "para",
};

/// Carries no polarity on its own; only ever accompanies a decision word.
const FILLER = [_][]const u8{
    "it",     "this",  "that",   "the",  "one",  "now",  "please",
    "then",   "email", "reply",  "message", "mind", "on", "up",
    "for",    "thanks",
};

fn inList(word: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

/// Splits on anything that isn't a letter or digit, so punctuation and
/// accented characters don't break matching ("sí," / "yes!").
fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

pub fn decide(text: []const u8) Decision {
    var words: [MAX_WORDS][]const u8 = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isWordByte(text[i])) i += 1;
        const start = i;
        while (i < text.len and isWordByte(text[i])) i += 1;
        if (i == start) break;
        if (count == MAX_WORDS) return .unclear; // too long to be an answer
        words[count] = text[start..i];
        count += 1;
    }
    if (count == 0) return .unclear;

    const found = words[0..count];

    // Negation wins, and is checked first: "dont send it" must not match on
    // "send".
    for (found) |word| {
        if (inList(word, &NO_WORDS)) return .cancel;
    }

    var has_yes = false;
    for (found) |word| {
        if (inList(word, &YES_WORDS)) {
            has_yes = true;
        } else if (!inList(word, &FILLER)) {
            // A word carrying meaning of its own: this is a request, not an
            // answer.
            return .unclear;
        }
    }
    return if (has_yes) .confirm else .unclear;
}

test "plain agreement confirms" {
    try std.testing.expectEqual(Decision.confirm, decide("yes"));
    try std.testing.expectEqual(Decision.confirm, decide("Yes"));
    try std.testing.expectEqual(Decision.confirm, decide("ok"));
    try std.testing.expectEqual(Decision.confirm, decide("do it"));
    try std.testing.expectEqual(Decision.confirm, decide("send it"));
    try std.testing.expectEqual(Decision.confirm, decide("ok go ahead"));
    try std.testing.expectEqual(Decision.confirm, decide("yes send it now"));
    try std.testing.expectEqual(Decision.confirm, decide("perfect go"));
    try std.testing.expectEqual(Decision.confirm, decide("go for it"));
}

test "spanish agreement confirms" {
    try std.testing.expectEqual(Decision.confirm, decide("sí"));
    try std.testing.expectEqual(Decision.confirm, decide("vale"));
    try std.testing.expectEqual(Decision.confirm, decide("dale"));
}

test "negation cancels and is checked before any yes word" {
    try std.testing.expectEqual(Decision.cancel, decide("no"));
    try std.testing.expectEqual(Decision.cancel, decide("nope"));
    try std.testing.expectEqual(Decision.cancel, decide("cancel it"));
    // These contain "send" and "do"; negation must win.
    try std.testing.expectEqual(Decision.cancel, decide("dont send it"));
    try std.testing.expectEqual(Decision.cancel, decide("do not send"));
    try std.testing.expectEqual(Decision.cancel, decide("no dont"));
    try std.testing.expectEqual(Decision.cancel, decide("wait"));
    try std.testing.expectEqual(Decision.cancel, decide("hold on"));
    try std.testing.expectEqual(Decision.cancel, decide("forget it"));
    try std.testing.expectEqual(Decision.cancel, decide("never mind"));
}

test "anything unclear must not send" {
    try std.testing.expectEqual(Decision.unclear, decide("hmm"));
    try std.testing.expectEqual(Decision.unclear, decide(""));
    try std.testing.expectEqual(Decision.unclear, decide("say Thursday instead"));
    try std.testing.expectEqual(Decision.unclear, decide("make it shorter"));
    try std.testing.expectEqual(Decision.unclear, decide("actually change the wording a bit"));
    try std.testing.expectEqual(Decision.unclear, decide("maybe later today or tomorrow"));
}

test "punctuation and case do not defeat matching" {
    try std.testing.expectEqual(Decision.confirm, decide("yes!"));
    try std.testing.expectEqual(Decision.confirm, decide("  OK.  "));
    try std.testing.expectEqual(Decision.cancel, decide("No."));
}
