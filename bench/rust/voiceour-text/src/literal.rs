//! `LiteralComposition` (LiteralComposition.swift): spoken spelling and symbol commands.

use std::borrow::Cow;

use crate::uni;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Word,
    Whitespace,
    Punctuation,
}

/// A token is a contiguous run of same-kind Characters, so it is a slice of the input;
/// command output owns its text.
struct Token<'a> {
    text: Cow<'a, str>,
    kind: Kind,
}

fn tokenize(text: &str) -> Vec<Token<'_>> {
    let mut tokens: Vec<Token<'_>> = Vec::new();
    let mut start = 0;
    let mut current: Option<Kind> = None;
    for (index, g) in uni::grapheme_indices(text) {
        let kind = if uni::ch_is_letter(g) || uni::ch_is_number(g) {
            Kind::Word
        } else if uni::ch_is_whitespace(g) {
            Kind::Whitespace
        } else {
            Kind::Punctuation
        };
        if current != Some(kind) {
            if let Some(previous) = current {
                tokens.push(Token {
                    text: Cow::Borrowed(&text[start..index]),
                    kind: previous,
                });
            }
            start = index;
            current = Some(kind);
        }
    }
    if let Some(kind) = current {
        tokens.push(Token {
            text: Cow::Borrowed(&text[start..]),
            kind,
        });
    }
    tokens
}

/// `token.text.lowercased() == expected` for an ASCII `expected`.
fn lowercase_equals(text: &str, expected: &str) -> bool {
    if text.is_ascii() {
        return text.len() == expected.len() && text.eq_ignore_ascii_case(expected);
    }
    uni::canon_eq(&uni::lowercased(text), expected)
}

fn word(expected: &str, token: &Token<'_>) -> bool {
    token.kind == Kind::Word && lowercase_equals(&token.text, expected)
}

fn spoken_word(expected: &str, index: usize, tokens: &[Token<'_>]) -> bool {
    if index >= tokens.len()
        || !word(expected, &tokens[index])
        || !(index == 0 || tokens[index - 1].kind == Kind::Whitespace)
    {
        return false;
    }
    index + 1 == tokens.len() || tokens[index + 1].kind == Kind::Whitespace
}

fn match_words(words: &[&str], start: usize, tokens: &[Token<'_>]) -> Option<usize> {
    if words.is_empty()
        || start >= tokens.len()
        || !(start == 0 || tokens[start - 1].kind == Kind::Whitespace)
    {
        return None;
    }
    let mut index = start;
    for (offset, expected) in words.iter().enumerate() {
        if index >= tokens.len() || !word(expected, &tokens[index]) {
            return None;
        }
        index += 1;
        if offset < words.len() - 1 {
            if index >= tokens.len() || tokens[index].kind != Kind::Whitespace {
                return None;
            }
            index += 1;
        }
    }
    if !(index == tokens.len() || tokens[index].kind == Kind::Whitespace) {
        return None;
    }
    Some(index)
}

fn match_letter_by_letter(start: usize, tokens: &[Token<'_>]) -> Option<usize> {
    if let Some(end) = match_words(&["letter", "by", "letter"], start, tokens) {
        return Some(end);
    }
    let hyphen = |token: &Token<'_>| token.kind == Kind::Punctuation && token.text == "-";
    if !(start + 4 < tokens.len()
        && (start == 0 || tokens[start - 1].kind == Kind::Whitespace)
        && word("letter", &tokens[start])
        && hyphen(&tokens[start + 1])
        && word("by", &tokens[start + 2])
        && hyphen(&tokens[start + 3])
        && word("letter", &tokens[start + 4]))
    {
        return None;
    }
    let end = start + 5;
    if !(end == tokens.len() || tokens[end].kind == Kind::Whitespace) {
        return None;
    }
    Some(end)
}

fn word_operand(command_end: usize, tokens: &[Token<'_>]) -> Option<usize> {
    if command_end + 1 < tokens.len()
        && tokens[command_end].kind == Kind::Whitespace
        && tokens[command_end + 1].kind == Kind::Word
    {
        Some(command_end + 1)
    } else {
        None
    }
}

fn word_sequence<'t, 'a>(start: usize, tokens: &'t [Token<'a>]) -> (Vec<&'t str>, usize) {
    let mut words = Vec::new();
    let mut index = start;
    while index < tokens.len() && tokens[index].kind == Kind::Word {
        words.push(tokens[index].text.as_ref());
        index += 1;
        if !(index + 1 < tokens.len()
            && tokens[index].kind == Kind::Whitespace
            && tokens[index + 1].kind == Kind::Word)
        {
            break;
        }
        index += 1;
    }
    (words, index)
}

fn spell(words: &[&str]) -> String {
    let mut result = String::new();
    let mut index = 0;
    while index < words.len() {
        let normalized = words[index];
        if (lowercase_equals(normalized, "capital") || lowercase_equals(normalized, "uppercase"))
            && index + 1 < words.len()
        {
            uni::push_uppercased(&mut result, words[index + 1]);
            index += 2;
        } else if lowercase_equals(normalized, "dash")
            && index + 1 < words.len()
            && lowercase_equals(words[index + 1], "dash")
        {
            result.push_str("--");
            index += 2;
        } else if lowercase_equals(normalized, "dash") {
            result.push('-');
            index += 1;
        } else if lowercase_equals(normalized, "dot") {
            result.push('.');
            index += 1;
        } else if lowercase_equals(normalized, "underscore") {
            result.push('_');
            index += 1;
        } else {
            result.push_str(words[index]);
            index += 1;
        }
    }
    result
}

fn literal(word: &str) -> String {
    if lowercase_equals(word, "dash") {
        "-".to_owned()
    } else if lowercase_equals(word, "dot") {
        ".".to_owned()
    } else if lowercase_equals(word, "underscore") {
        "_".to_owned()
    } else {
        word.to_owned()
    }
}

fn camel_case(words: &[&str]) -> String {
    let Some(first) = words.first() else {
        return String::new();
    };
    let mut out = uni::lowercased(first);
    for word in &words[1..] {
        let Some(initial) = uni::graphemes(word).next() else {
            continue;
        };
        uni::push_uppercased(&mut out, initial);
        uni::push_lowercased(&mut out, &word[initial.len()..]);
    }
    out
}

fn append_symbol(symbol: &'static str, output: &mut Vec<Token<'_>>) {
    if output
        .last()
        .is_some_and(|token| token.kind == Kind::Whitespace)
    {
        output.pop();
    }
    output.push(Token {
        text: Cow::Borrowed(symbol),
        kind: Kind::Punctuation,
    });
}

fn skip_whitespace(index: usize, tokens: &[Token<'_>]) -> usize {
    if index < tokens.len() && tokens[index].kind == Kind::Whitespace {
        index + 1
    } else {
        index
    }
}

fn owned_word<'a>(text: String) -> Token<'a> {
    Token {
        text: Cow::Owned(text),
        kind: Kind::Word,
    }
}

/// `LiteralComposition.apply(_:)`.
pub fn apply(transcript: &str) -> Cow<'_, str> {
    let tokens = tokenize(transcript);
    let mut output: Vec<Token<'_>> = Vec::with_capacity(tokens.len());
    let mut index = 0;
    let mut changed = false;

    while index < tokens.len() {
        if let Some(operand) = match_words(&["spell", "that"], index, &tokens)
            .and_then(|end| word_operand(end, &tokens))
        {
            let (words, end) = word_sequence(operand, &tokens);
            output.push(owned_word(spell(&words)));
            index = end;
            changed = true;
            continue;
        }
        if spoken_word("spell", index, &tokens) {
            if let Some(operand) = word_operand(index + 1, &tokens) {
                let (words, end) = word_sequence(operand, &tokens);
                output.push(owned_word(spell(&words)));
                index = end;
                changed = true;
                continue;
            }
        }
        if let Some(operand) =
            match_letter_by_letter(index, &tokens).and_then(|end| word_operand(end, &tokens))
        {
            let (words, end) = word_sequence(operand, &tokens);
            output.push(owned_word(spell(&words)));
            index = end;
            changed = true;
            continue;
        }
        if spoken_word("literal", index, &tokens) {
            if let Some(operand) = word_operand(index + 1, &tokens) {
                output.push(owned_word(literal(&tokens[operand].text)));
                index = operand + 1;
                changed = true;
                continue;
            }
        }
        if let Some(operand) = match_words(&["snake", "case"], index, &tokens)
            .and_then(|end| word_operand(end, &tokens))
        {
            let (words, end) = word_sequence(operand, &tokens);
            let mut snake = String::new();
            for (position, word) in words.iter().enumerate() {
                if position > 0 {
                    snake.push('_');
                }
                uni::push_lowercased(&mut snake, word);
            }
            output.push(owned_word(snake));
            index = end;
            changed = true;
            continue;
        }
        if let Some(operand) = match_words(&["camel", "case"], index, &tokens)
            .and_then(|end| word_operand(end, &tokens))
        {
            let (words, end) = word_sequence(operand, &tokens);
            output.push(owned_word(camel_case(&words)));
            index = end;
            changed = true;
            continue;
        }
        if spoken_word("capital", index, &tokens) || spoken_word("uppercase", index, &tokens) {
            if let Some(operand) = word_operand(index + 1, &tokens) {
                output.push(owned_word(uni::uppercased(&tokens[operand].text)));
                index = operand + 1;
                changed = true;
                continue;
            }
        }
        if let Some(end) = match_words(&["dash", "dash"], index, &tokens) {
            append_symbol("--", &mut output);
            index = skip_whitespace(end, &tokens);
            changed = true;
            continue;
        }
        if spoken_word("dash", index, &tokens) {
            append_symbol("-", &mut output);
            index = skip_whitespace(index + 1, &tokens);
            changed = true;
            continue;
        }
        if spoken_word("dot", index, &tokens) {
            append_symbol(".", &mut output);
            index = skip_whitespace(index + 1, &tokens);
            changed = true;
            continue;
        }
        if spoken_word("underscore", index, &tokens) {
            append_symbol("_", &mut output);
            index = skip_whitespace(index + 1, &tokens);
            changed = true;
            continue;
        }
        output.push(Token {
            text: tokens[index].text.clone(),
            kind: tokens[index].kind,
        });
        index += 1;
    }

    if !changed {
        return Cow::Borrowed(transcript);
    }
    let mut result = String::with_capacity(transcript.len());
    for token in &output {
        result.push_str(&token.text);
    }
    Cow::Owned(result)
}
