use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

const MAX_UNDO_STEPS: usize = 1_000;
const TYPING_GROUP_DELAY: Duration = Duration::from_millis(750);

#[derive(Debug)]
struct EditSnapshot {
    text: String,
    cursor: usize,
    cursor_anchor: usize,
}

#[derive(Debug)]
pub struct Document {
    pub id: u64,
    pub path: Option<PathBuf>,
    pub text: String,
    pub cursor: usize,
    pub cursor_anchor: usize,
    pub restore_cursor: bool,
    saved_text: String,
    observed_text: String,
    undo: Vec<EditSnapshot>,
    redo: Vec<EditSnapshot>,
    last_grouped_edit: Option<Instant>,
    modified_at: Option<SystemTime>,
}

impl Document {
    pub fn untitled(id: u64) -> Self {
        Self {
            id,
            path: None,
            text: String::new(),
            cursor: 0,
            cursor_anchor: 0,
            restore_cursor: false,
            saved_text: String::new(),
            observed_text: String::new(),
            undo: Vec::new(),
            redo: Vec::new(),
            last_grouped_edit: None,
            modified_at: None,
        }
    }

    pub fn open(id: u64, path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let text = fs::read_to_string(&path)?;
        let modified_at = fs::metadata(&path)
            .and_then(|metadata| metadata.modified())
            .ok();
        Ok(Self {
            id,
            path: Some(path),
            saved_text: text.clone(),
            observed_text: text.clone(),
            text,
            cursor: 0,
            cursor_anchor: 0,
            restore_cursor: false,
            undo: Vec::new(),
            redo: Vec::new(),
            last_grouped_edit: None,
            modified_at,
        })
    }

    pub fn is_dirty(&self) -> bool {
        self.text != self.saved_text
    }

    pub fn record_text_edit(&mut self, cursor: usize, cursor_anchor: usize, group: bool) {
        if self.text == self.observed_text {
            return;
        }
        let now = Instant::now();
        let grouped = group
            && self
                .last_grouped_edit
                .is_some_and(|last| now.duration_since(last) <= TYPING_GROUP_DELAY);
        if !grouped {
            self.undo.push(EditSnapshot {
                text: std::mem::take(&mut self.observed_text),
                cursor,
                cursor_anchor,
            });
            if self.undo.len() > MAX_UNDO_STEPS {
                self.undo.remove(0);
            }
        }
        self.observed_text.clone_from(&self.text);
        self.redo.clear();
        self.last_grouped_edit = group.then_some(now);
    }

    pub fn undo(&mut self) -> bool {
        let Some(snapshot) = self.undo.pop() else {
            return false;
        };
        self.redo.push(EditSnapshot {
            text: std::mem::replace(&mut self.text, snapshot.text),
            cursor: self.cursor,
            cursor_anchor: self.cursor_anchor,
        });
        self.cursor = snapshot.cursor.min(self.text.chars().count());
        self.cursor_anchor = snapshot.cursor_anchor.min(self.text.chars().count());
        self.observed_text.clone_from(&self.text);
        self.restore_cursor = true;
        self.last_grouped_edit = None;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(snapshot) = self.redo.pop() else {
            return false;
        };
        self.undo.push(EditSnapshot {
            text: std::mem::replace(&mut self.text, snapshot.text),
            cursor: self.cursor,
            cursor_anchor: self.cursor_anchor,
        });
        self.cursor = snapshot.cursor.min(self.text.chars().count());
        self.cursor_anchor = snapshot.cursor_anchor.min(self.text.chars().count());
        self.observed_text.clone_from(&self.text);
        self.restore_cursor = true;
        self.last_grouped_edit = None;
        true
    }

    pub fn insert_indented_newline(&mut self, indent_unit: &str) {
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        self.insert_indented_newline_from(indent_unit, previous_cursor, previous_anchor);
    }

    fn insert_indented_newline_from(
        &mut self,
        indent_unit: &str,
        previous_cursor: usize,
        previous_anchor: usize,
    ) {
        let start = self.char_to_byte_offset(self.cursor.min(self.cursor_anchor));
        let end = self.char_to_byte_offset(self.cursor.max(self.cursor_anchor));
        let line_start = self.text[..start]
            .rfind('\n')
            .map_or(0, |offset| offset + 1);
        let line_prefix = &self.text[line_start..start];
        let base_indent = line_prefix
            .chars()
            .take_while(|character| matches!(character, ' ' | '\t'))
            .collect::<String>();
        let previous_significant = line_prefix
            .chars()
            .rev()
            .find(|character| !character.is_whitespace());
        let extra_indent = if matches!(previous_significant, Some('{' | '(' | '[')) {
            indent_unit
        } else {
            ""
        };
        let matching_closer = match previous_significant {
            Some('{') => Some('}'),
            Some('(') => Some(')'),
            Some('[') => Some(']'),
            _ => None,
        };
        let split_pair = matching_closer.is_some_and(|closer| self.text[end..].starts_with(closer));
        let insertion = if split_pair {
            format!("\n{base_indent}{extra_indent}\n{base_indent}")
        } else {
            format!("\n{base_indent}{extra_indent}")
        };
        let cursor_byte = start + 1 + base_indent.len() + extra_indent.len();
        self.text.replace_range(start..end, &insertion);
        self.cursor = self.text[..cursor_byte].chars().count();
        self.cursor_anchor = self.cursor;
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn insert_newline_below(&mut self, indent_unit: &str) {
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let line_end = self
            .text
            .char_indices()
            .skip(self.cursor)
            .find_map(|(offset, character)| (character == '\n').then_some(offset))
            .unwrap_or(self.text.len());
        let cursor = self.byte_to_char_offset(line_end);
        self.cursor = cursor;
        self.cursor_anchor = cursor;
        self.insert_indented_newline_from(indent_unit, previous_cursor, previous_anchor);
    }

    pub fn insert_newline_above(&mut self, indent_unit: &str) {
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let cursor_byte = self.char_to_byte_offset(self.cursor.min(self.cursor_anchor));
        let line_start = self.text[..cursor_byte]
            .rfind('\n')
            .map_or(0, |offset| offset + 1);
        let line_end = self.text[line_start..]
            .find('\n')
            .map_or(self.text.len(), |offset| line_start + offset);
        let line = &self.text[line_start..line_end];
        let base_indent = line
            .chars()
            .take_while(|character| matches!(character, ' ' | '\t'))
            .collect::<String>();
        let first_content = line[base_indent.len()..].chars().next();
        let extra_indent = if matches!(first_content, Some('}' | ')' | ']')) {
            indent_unit
        } else {
            ""
        };
        let insertion = format!("{base_indent}{extra_indent}\n");
        self.text.insert_str(line_start, &insertion);
        let caret_byte = line_start + base_indent.len() + extra_indent.len();
        self.cursor = self.byte_to_char_offset(caret_byte);
        self.cursor_anchor = self.cursor;
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn insert_tab_indent(&mut self, indent_unit: &str, tab_width: usize, insert_spaces: bool) {
        if tab_width == 0 {
            return;
        }
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let cursor_byte = self.char_to_byte_offset(self.cursor);
        let anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        let start = cursor_byte.min(anchor_byte);
        let end = cursor_byte.max(anchor_byte);
        let first_line_start = self.text[..start]
            .rfind('\n')
            .map_or(0, |offset| offset + 1);
        let mut line_starts = vec![first_line_start];
        let mut search_from = first_line_start;
        while search_from < end {
            let Some(newline) = self.text[search_from..end].find('\n') else {
                break;
            };
            let next_line_start = search_from + newline + 1;
            if next_line_start >= end {
                break;
            }
            line_starts.push(next_line_start);
            search_from = next_line_start;
        }

        let (new_cursor_byte, new_anchor_byte) = if line_starts.len() > 1 {
            for line_start in line_starts.iter().rev() {
                self.text.insert_str(*line_start, indent_unit);
            }
            let cursor_shift = line_starts
                .iter()
                .filter(|line_start| **line_start <= cursor_byte)
                .count()
                * indent_unit.len();
            let anchor_shift = line_starts
                .iter()
                .filter(|line_start| **line_start <= anchor_byte)
                .count()
                * indent_unit.len();
            (cursor_byte + cursor_shift, anchor_byte + anchor_shift)
        } else {
            let prefix = &self.text[first_line_start..start];
            let column = prefix.chars().fold(0, |column, character| {
                if character == '\t' {
                    column + tab_width - column % tab_width
                } else {
                    column + 1
                }
            });
            let insertion = if insert_spaces {
                " ".repeat(tab_width - column % tab_width)
            } else {
                "\t".to_owned()
            };
            self.text.replace_range(start..end, &insertion);
            let caret = start + insertion.len();
            (caret, caret)
        };
        self.cursor = self.text[..new_cursor_byte].chars().count();
        self.cursor_anchor = self.text[..new_anchor_byte].chars().count();
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn indent_selection(&mut self, indent_unit: &str) {
        if indent_unit.is_empty() {
            return;
        }
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let cursor_byte = self.char_to_byte_offset(self.cursor);
        let anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        let start = cursor_byte.min(anchor_byte);
        let end = cursor_byte.max(anchor_byte);
        let first_line_start = self.text[..start]
            .rfind('\n')
            .map_or(0, |offset| offset + 1);
        let end_line_start = self.text[..end].rfind('\n').map_or(0, |offset| offset + 1);
        let last_line_start = if end_line_start != first_line_start && end_line_start == end {
            self.text[..end_line_start]
                .rfind('\n')
                .map_or(0, |offset| offset + 1)
        } else {
            end_line_start
        };
        let mut line_starts = vec![first_line_start];
        let mut search_from = first_line_start;
        while search_from < last_line_start {
            let Some(newline) = self.text[search_from..last_line_start].find('\n') else {
                break;
            };
            search_from += newline + 1;
            line_starts.push(search_from);
        }

        let mut inserted = Vec::new();
        for line_start in line_starts.iter().rev() {
            let line_end = self.text[*line_start..]
                .find('\n')
                .map_or(self.text.len(), |offset| *line_start + offset);
            if line_end == *line_start {
                continue;
            }
            self.text.insert_str(*line_start, indent_unit);
            inserted.push(*line_start);
        }
        if inserted.is_empty() {
            return;
        }
        let cursor_shift = inserted
            .iter()
            .filter(|line_start| **line_start <= cursor_byte)
            .count()
            * indent_unit.len();
        let anchor_shift = inserted
            .iter()
            .filter(|line_start| **line_start <= anchor_byte)
            .count()
            * indent_unit.len();
        let new_cursor = cursor_byte + cursor_shift;
        let new_anchor = anchor_byte + anchor_shift;
        self.cursor = self.text[..new_cursor].chars().count();
        self.cursor_anchor = self.text[..new_anchor].chars().count();
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn outdent_selection(&mut self, tab_width: usize) {
        let tab_width = tab_width.max(1);
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let cursor_byte = self.char_to_byte_offset(self.cursor);
        let anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        let start = cursor_byte.min(anchor_byte);
        let end = cursor_byte.max(anchor_byte);
        let first_line_start = self.text[..start]
            .rfind('\n')
            .map_or(0, |offset| offset + 1);
        let end_line_start = self.text[..end].rfind('\n').map_or(0, |offset| offset + 1);
        let include_end_line = end_line_start == first_line_start || end_line_start != end;
        let mut line_starts = vec![first_line_start];
        let mut search_from = first_line_start;
        let last_line_start = if include_end_line {
            end_line_start
        } else {
            self.text[..end_line_start]
                .rfind('\n')
                .map_or(0, |offset| offset + 1)
        };
        while search_from < last_line_start {
            let Some(newline) = self.text[search_from..last_line_start].find('\n') else {
                break;
            };
            search_from += newline + 1;
            line_starts.push(search_from);
        }
        let mut removed_before_cursor = 0;
        let mut removed_before_anchor = 0;
        let mut removed = false;
        for line_start in line_starts.iter().rev() {
            let Some(first) = self.text[*line_start..].chars().next() else {
                continue;
            };
            let count = if first == '\t' {
                1
            } else if first == ' ' {
                self.text[*line_start..]
                    .chars()
                    .take(tab_width)
                    .take_while(|character| *character == ' ')
                    .count()
                    .min(tab_width)
            } else {
                0
            };
            if count == 0 {
                continue;
            }
            let removal_end = *line_start
                + self.text[*line_start..]
                    .chars()
                    .take(count)
                    .map(char::len_utf8)
                    .sum::<usize>();
            self.text.replace_range(*line_start..removal_end, "");
            if *line_start < cursor_byte {
                removed_before_cursor += count;
            }
            if *line_start < anchor_byte {
                removed_before_anchor += count;
            }
            removed = true;
        }
        if removed {
            let new_cursor = cursor_byte.saturating_sub(removed_before_cursor);
            let new_anchor = anchor_byte.saturating_sub(removed_before_anchor);
            self.cursor = self.text[..new_cursor.min(self.text.len())].chars().count();
            self.cursor_anchor = self.text[..new_anchor.min(self.text.len())].chars().count();
            self.restore_cursor = true;
            self.record_text_edit(previous_cursor, previous_anchor, false);
        }
    }

    pub fn type_paired_character(&mut self, character: char) -> bool {
        let closing = match character {
            '(' => Some(')'),
            '[' => Some(']'),
            '{' => Some('}'),
            '"' | '\'' | '`' => Some(character),
            ')' | ']' | '}' => {
                let cursor = self.char_to_byte_offset(self.cursor);
                let anchor = self.char_to_byte_offset(self.cursor_anchor);
                if cursor == anchor && self.text[cursor..].starts_with(character) {
                    self.set_cursor_byte_offset(cursor + character.len_utf8());
                    return true;
                }
                None
            }
            _ => None,
        };
        let Some(closing) = closing else {
            return false;
        };
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let cursor_byte = self.char_to_byte_offset(self.cursor);
        let anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        let start = cursor_byte.min(anchor_byte);
        let end = cursor_byte.max(anchor_byte);
        if start == end {
            if matches!(character, '"' | '\'' | '`')
                && (self.text[..start]
                    .chars()
                    .next_back()
                    .is_some_and(|character| character.is_alphanumeric() || character == '_')
                    || self.text[start..]
                        .chars()
                        .next()
                        .is_some_and(|character| character.is_alphanumeric() || character == '_'))
            {
                return false;
            }
            if !self.text[end..].chars().next().is_none_or(|next| {
                next.is_whitespace() || matches!(next, ')' | ']' | '}' | ',' | ';')
            }) {
                return false;
            }
            self.text
                .insert_str(start, &format!("{character}{closing}"));
            let cursor = self.text[..start + character.len_utf8()].chars().count();
            self.cursor = cursor;
            self.cursor_anchor = cursor;
        } else {
            self.text.insert(start, character);
            self.text.insert(end + character.len_utf8(), closing);
            self.cursor_anchor = self.text[..start + character.len_utf8()].chars().count();
            self.cursor = self.text[..end + character.len_utf8()].chars().count();
        }
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
        true
    }

    pub fn duplicate_selected_lines(&mut self) {
        let starts = Self::line_starts(&self.text);
        let (first, last) =
            Self::selected_line_range(&self.text, &starts, self.cursor, self.cursor_anchor);
        let mut lines = self.text.split('\n').map(str::to_owned).collect::<Vec<_>>();
        let copies = lines[first..=last].to_vec();
        let count = copies.len();
        lines.splice(last + 1..last + 1, copies);
        self.replace_lines_preserving_endpoints(lines, |line| {
            if line >= first { line + count } else { line }
        });
    }

    pub fn delete_selected_lines(&mut self) {
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let starts = Self::line_starts(&self.text);
        let (first, last) =
            Self::selected_line_range(&self.text, &starts, self.cursor, self.cursor_anchor);
        let mut lines = self.text.split('\n').map(str::to_owned).collect::<Vec<_>>();
        lines.drain(first..=last);
        if lines.is_empty() {
            lines.push(String::new());
        }
        self.text = lines.join("\n");
        let line = first.min(lines.len() - 1);
        let cursor = Self::line_start_offset(&self.text, line);
        self.cursor = self.text[..cursor].chars().count();
        self.cursor_anchor = self.cursor;
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn move_selected_lines(&mut self, down: bool) -> bool {
        let starts = Self::line_starts(&self.text);
        let (first, last) =
            Self::selected_line_range(&self.text, &starts, self.cursor, self.cursor_anchor);
        let line_count = starts.len();
        if (down && last + 1 >= line_count) || (!down && first == 0) {
            return false;
        }
        let mut lines = self.text.split('\n').map(str::to_owned).collect::<Vec<_>>();
        if down {
            lines[first..=last + 1].rotate_right(1);
        } else {
            lines[first - 1..=last].rotate_left(1);
        }
        self.replace_lines_preserving_endpoints(lines, |line| {
            if down {
                if line == last + 1 {
                    first
                } else if (first..=last).contains(&line) {
                    line + 1
                } else {
                    line
                }
            } else if line == first - 1 {
                last
            } else if (first..=last).contains(&line) {
                line - 1
            } else {
                line
            }
        });
        true
    }

    pub fn select_line(&mut self) {
        let starts = Self::line_starts(&self.text);
        let (first, mut last) =
            Self::selected_line_range(&self.text, &starts, self.cursor, self.cursor_anchor);
        let selected_start = self.char_to_byte_offset(self.cursor.min(self.cursor_anchor));
        let selected_end = self.char_to_byte_offset(self.cursor.max(self.cursor_anchor));
        let current_line_start = starts[first];
        let current_line_end = starts.get(last + 1).copied().unwrap_or(self.text.len());
        if selected_start == current_line_start
            && selected_end == current_line_end
            && last + 1 < starts.len()
        {
            last += 1;
        }
        self.cursor_anchor = self.byte_to_char_offset(starts[first]);
        self.cursor =
            self.byte_to_char_offset(starts.get(last + 1).copied().unwrap_or(self.text.len()));
    }

    pub fn toggle_line_comments(&mut self, token: &str) -> bool {
        if token.is_empty() {
            return false;
        }
        let starts = Self::line_starts(&self.text);
        let (first, last) =
            Self::selected_line_range(&self.text, &starts, self.cursor, self.cursor_anchor);
        let lines = self.text.split('\n').collect::<Vec<_>>();
        let nonblank = (first..=last)
            .filter_map(|line| {
                let content = lines[line];
                let indent = content.len() - content.trim_start_matches([' ', '\t']).len();
                (indent < content.len()).then_some((line, indent, content))
            })
            .collect::<Vec<_>>();
        if nonblank.is_empty() {
            return false;
        }

        let uncomment = nonblank
            .iter()
            .all(|(_, indent, line)| line[*indent..].starts_with(token));
        let minimum_indent = nonblank
            .iter()
            .map(|(_, indent, line)| line[..*indent].chars().count())
            .min()
            .unwrap_or(0);
        let edits = nonblank
            .iter()
            .map(|(line, indent, content)| {
                let line_start = starts[*line];
                if uncomment {
                    let start = line_start + indent;
                    let mut end = start + token.len();
                    if content[end - line_start..].starts_with(' ') {
                        end += 1;
                    }
                    (start, end, String::new())
                } else {
                    let indent_end = content
                        .char_indices()
                        .nth(minimum_indent)
                        .map_or(*indent, |(offset, _)| offset);
                    (
                        line_start + indent_end,
                        line_start + indent_end,
                        format!("{token} "),
                    )
                }
            })
            .collect::<Vec<_>>();
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let mut cursor_byte = self.char_to_byte_offset(self.cursor);
        let mut anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        for (start, end, replacement) in edits.iter().rev() {
            let delta = replacement.len() as isize - (end - start) as isize;
            cursor_byte = Self::adjust_offset(cursor_byte, *start, *end, replacement.len(), delta);
            anchor_byte = Self::adjust_offset(anchor_byte, *start, *end, replacement.len(), delta);
            self.text.replace_range(*start..*end, replacement);
        }
        self.cursor = self.byte_to_char_offset(cursor_byte);
        self.cursor_anchor = self.byte_to_char_offset(anchor_byte);
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
        true
    }

    fn adjust_offset(
        offset: usize,
        start: usize,
        end: usize,
        inserted: usize,
        delta: isize,
    ) -> usize {
        if start == end {
            if offset >= start {
                offset + inserted
            } else {
                offset
            }
        } else if offset < start {
            offset
        } else if offset <= end {
            start + inserted
        } else {
            offset.saturating_add_signed(delta)
        }
    }

    fn replace_lines_preserving_endpoints(
        &mut self,
        lines: Vec<String>,
        map_line: impl Fn(usize) -> usize,
    ) {
        let old_starts = Self::line_starts(&self.text);
        let (cursor_line, cursor_column) =
            Self::line_and_column(&self.text, &old_starts, self.cursor);
        let (anchor_line, anchor_column) =
            Self::line_and_column(&self.text, &old_starts, self.cursor_anchor);
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        self.text = lines.join("\n");
        self.cursor = Self::offset_at_line_column(&self.text, map_line(cursor_line), cursor_column);
        self.cursor_anchor =
            Self::offset_at_line_column(&self.text, map_line(anchor_line), anchor_column);
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    pub fn cursor_byte_offset(&self) -> usize {
        self.char_to_byte_offset(self.cursor)
    }

    fn line_starts(text: &str) -> Vec<usize> {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(offset, _)| offset + 1));
        starts
    }

    fn selected_line_range(
        text: &str,
        starts: &[usize],
        cursor: usize,
        anchor: usize,
    ) -> (usize, usize) {
        let cursor_byte = Self::char_offset_to_byte(text, cursor);
        let anchor_byte = Self::char_offset_to_byte(text, anchor);
        let start = cursor_byte.min(anchor_byte);
        let end = cursor_byte.max(anchor_byte);
        let first = starts.partition_point(|line_start| *line_start <= start) - 1;
        let mut last = starts.partition_point(|line_start| *line_start <= end) - 1;
        if last > first && starts[last] == end {
            last -= 1;
        }
        (first, last)
    }

    fn char_offset_to_byte(text: &str, character: usize) -> usize {
        text.char_indices()
            .nth(character)
            .map_or(text.len(), |(offset, _)| offset)
    }

    fn line_and_column(text: &str, starts: &[usize], character: usize) -> (usize, usize) {
        let byte = Self::char_offset_to_byte(text, character);
        let line = starts.partition_point(|line_start| *line_start <= byte) - 1;
        let column = text[starts[line]..byte].chars().count();
        (line, column)
    }

    fn line_start_offset(text: &str, line: usize) -> usize {
        Self::line_starts(text)
            .get(line)
            .copied()
            .unwrap_or(text.len())
    }

    fn offset_at_line_column(text: &str, line: usize, column: usize) -> usize {
        let starts = Self::line_starts(text);
        let lines = text.split('\n').collect::<Vec<_>>();
        let line = line.min(lines.len() - 1);
        starts[line]
            + lines[line]
                .char_indices()
                .nth(column)
                .map_or(lines[line].len(), |(offset, _)| offset)
    }

    pub fn set_cursor_byte_offset(&mut self, offset: usize) {
        self.set_selection_byte_offsets(offset, offset);
    }

    pub fn cursor_anchor_byte_offset(&self) -> usize {
        self.char_to_byte_offset(self.cursor_anchor)
    }

    pub fn set_selection_byte_offsets(&mut self, anchor: usize, cursor: usize) {
        self.cursor_anchor = self.byte_to_char_offset(anchor);
        self.cursor = self.byte_to_char_offset(cursor);
        self.restore_cursor = true;
    }

    fn char_to_byte_offset(&self, character: usize) -> usize {
        self.text
            .char_indices()
            .nth(character)
            .map_or(self.text.len(), |(offset, _)| offset)
    }

    fn byte_to_char_offset(&self, offset: usize) -> usize {
        let offset = offset.min(self.text.len());
        let offset = (0..=offset)
            .rev()
            .find(|candidate| self.text.is_char_boundary(*candidate))
            .unwrap_or(0);
        self.text[..offset].chars().count()
    }

    pub fn title(&self) -> String {
        match self.path.as_deref() {
            Some(path) => path
                .file_name()
                .unwrap_or(path.as_os_str())
                .to_string_lossy()
                .into_owned(),
            None => "Untitled".into(),
        }
    }

    pub fn save_with_options(
        &mut self,
        path: Option<&Path>,
        trim_trailing_whitespace: bool,
        final_newline: bool,
    ) -> io::Result<()> {
        let target = path
            .map(Path::to_path_buf)
            .or_else(|| self.path.clone())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "save path is required"))?;
        self.normalize_before_save(trim_trailing_whitespace, final_newline);
        fs::write(&target, self.text.as_bytes())?;
        self.path = Some(target.clone());
        self.saved_text.clone_from(&self.text);
        self.modified_at = fs::metadata(&target)
            .and_then(|metadata| metadata.modified())
            .ok();
        Ok(())
    }

    fn normalize_before_save(&mut self, trim_trailing_whitespace: bool, final_newline: bool) {
        let mut edits = Vec::<(usize, usize, String)>::new();
        if trim_trailing_whitespace {
            let mut line_start = 0;
            for line_end in self
                .text
                .match_indices('\n')
                .map(|(offset, _)| offset)
                .chain(std::iter::once(self.text.len()))
            {
                let mut trim_end = line_end;
                while trim_end > line_start
                    && matches!(self.text.as_bytes()[trim_end - 1], b' ' | b'\t')
                {
                    trim_end -= 1;
                }
                if trim_end < line_end {
                    edits.push((trim_end, line_end, String::new()));
                }
                line_start = line_end.saturating_add(1);
            }
        }
        if final_newline && !self.text.is_empty() && !self.text.ends_with('\n') {
            edits.push((self.text.len(), self.text.len(), "\n".into()));
        }
        if edits.is_empty() {
            return;
        }
        let previous_cursor = self.cursor;
        let previous_anchor = self.cursor_anchor;
        let mut cursor_byte = self.char_to_byte_offset(self.cursor);
        let mut anchor_byte = self.char_to_byte_offset(self.cursor_anchor);
        for (start, end, replacement) in edits.iter().rev() {
            let delta = replacement.len() as isize - (end - start) as isize;
            let is_final_newline = *start == *end && *end == self.text.len() && replacement == "\n";
            cursor_byte = if is_final_newline && cursor_byte == *start {
                cursor_byte
            } else {
                Self::adjust_offset(cursor_byte, *start, *end, replacement.len(), delta)
            };
            anchor_byte = if is_final_newline && anchor_byte == *start {
                anchor_byte
            } else {
                Self::adjust_offset(anchor_byte, *start, *end, replacement.len(), delta)
            };
            self.text.replace_range(*start..*end, replacement);
        }
        self.cursor = self.byte_to_char_offset(cursor_byte);
        self.cursor_anchor = self.byte_to_char_offset(anchor_byte);
        self.restore_cursor = true;
        self.record_text_edit(previous_cursor, previous_anchor, false);
    }

    /// Reload only unchanged buffers when their on-disk timestamp has advanced.
    pub fn reload_if_changed(&mut self) -> io::Result<bool> {
        let Some(path) = self.path.as_deref() else {
            return Ok(false);
        };
        let metadata = fs::metadata(path)?;
        let modified_at = metadata.modified().ok();
        if modified_at == self.modified_at {
            return Ok(false);
        }
        self.modified_at = modified_at;
        if self.is_dirty() {
            return Ok(false);
        }
        let text = fs::read_to_string(path)?;
        self.text = text;
        self.saved_text.clone_from(&self.text);
        self.observed_text.clone_from(&self.text);
        self.undo.clear();
        self.redo.clear();
        self.last_grouped_edit = None;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

    struct TestFile(PathBuf);

    impl TestFile {
        fn new() -> Self {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "rhun-document-test-{}-{id}.txt",
                std::process::id()
            ));
            Self(path)
        }
    }

    impl Drop for TestFile {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn opening_and_saving_tracks_dirty_state_and_path() {
        let file = TestFile::new();
        fs::write(&file.0, "first\n").unwrap();
        let mut doc = Document::open(1, &file.0).unwrap();
        assert_eq!(doc.text, "first\n");
        assert_eq!(doc.title(), file.0.file_name().unwrap().to_string_lossy());
        assert!(!doc.is_dirty());

        doc.text.push_str("second\n");
        assert!(doc.is_dirty());
        doc.save_with_options(None, false, false).unwrap();
        assert!(!doc.is_dirty());
        assert_eq!(fs::read_to_string(&file.0).unwrap(), "first\nsecond\n");
    }

    #[test]
    fn untitled_documents_require_an_explicit_save_path() {
        let file = TestFile::new();
        let mut doc = Document::untitled(2);
        doc.text = "new document".into();
        assert_eq!(doc.title(), "Untitled");
        assert_eq!(
            doc.save_with_options(None, false, false)
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
        doc.save_with_options(Some(&file.0), false, false).unwrap();
        assert_eq!(fs::read_to_string(&file.0).unwrap(), "new document");
        assert_eq!(doc.path.as_deref(), Some(file.0.as_path()));
    }

    #[test]
    fn save_options_trim_trailing_blanks_and_add_final_newline() {
        let file = TestFile::new();
        let mut doc = Document::untitled(24);
        doc.text = "first \t\nsecond  ".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_cursor_byte_offset(doc.text.len());

        doc.save_with_options(Some(&file.0), true, true).unwrap();

        assert_eq!(fs::read_to_string(&file.0).unwrap(), "first\nsecond\n");
        assert_eq!(doc.text, "first\nsecond\n");
        assert_eq!(doc.cursor_byte_offset(), "first\nsecond".len());
        assert!(!doc.is_dirty());
        assert!(doc.undo());
        assert_eq!(doc.text, "first \t\nsecond  ");
        assert!(doc.is_dirty());
    }

    #[test]
    fn save_options_can_leave_trailing_blanks_and_omit_final_newline() {
        let file = TestFile::new();
        let mut doc = Document::untitled(25);
        doc.text = "content  ".into();

        doc.save_with_options(Some(&file.0), false, false).unwrap();

        assert_eq!(fs::read_to_string(&file.0).unwrap(), "content  ");
        assert_eq!(doc.text, "content  ");
    }

    #[test]
    fn failed_save_keeps_normalized_buffer_dirty_and_returns_the_io_error() {
        let file = TestFile::new();
        let missing_parent = file.0.join("missing");
        let mut doc = Document::untitled(26);
        doc.text = "content  ".into();

        let error = doc
            .save_with_options(Some(&missing_parent), true, true)
            .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(doc.text, "content\n");
        assert!(doc.is_dirty());
        assert!(doc.path.is_none());
    }

    #[test]
    fn opening_a_missing_file_returns_the_io_error() {
        let file = TestFile::new();
        assert_eq!(
            Document::open(3, &file.0).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
    }

    #[test]
    fn saved_cursor_tracks_utf8_byte_offsets_and_clamps_to_boundaries() {
        let mut doc = Document::untitled(4);
        doc.text = "aé🙂z".into();

        doc.set_cursor_byte_offset(3);
        assert_eq!(doc.cursor, 2);
        assert_eq!(doc.cursor_byte_offset(), 3);

        doc.set_cursor_byte_offset(4);
        assert_eq!(doc.cursor, 2);
        assert_eq!(doc.cursor_byte_offset(), 3);

        doc.set_cursor_byte_offset(usize::MAX);
        assert_eq!(doc.cursor_byte_offset(), doc.text.len());
    }

    #[test]
    fn selections_round_trip_utf8_byte_offsets() {
        let mut doc = Document::untitled(5);
        doc.text = "aé🙂z".into();

        doc.set_selection_byte_offsets(1, 7);
        assert_eq!(doc.cursor_anchor_byte_offset(), 1);
        assert_eq!(doc.cursor_byte_offset(), 7);
        assert_eq!(doc.cursor_anchor, 1);
        assert_eq!(doc.cursor, 3);
    }

    #[test]
    fn undo_and_redo_restore_utf8_text_and_selection() {
        let mut doc = Document::untitled(6);
        doc.text = "aé".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = 2;
        doc.cursor_anchor = 1;

        doc.text.push('🙂');
        doc.record_text_edit(2, 1, false);
        assert!(doc.undo());
        assert_eq!(doc.text, "aé");
        assert_eq!((doc.cursor_anchor, doc.cursor), (1, 2));
        assert!(doc.restore_cursor);
        assert!(doc.redo());
        assert_eq!(doc.text, "aé🙂");
        assert_eq!((doc.cursor_anchor, doc.cursor), (1, 2));
    }

    #[test]
    fn adjacent_typing_edits_are_undone_as_one_step() {
        let mut doc = Document::untitled(7);
        doc.text = "a".into();
        doc.observed_text.clone_from(&doc.text);

        doc.text.push('b');
        doc.record_text_edit(1, 1, true);
        doc.text.push('c');
        doc.record_text_edit(2, 2, true);

        assert!(doc.undo());
        assert_eq!(doc.text, "a");
        assert!(!doc.undo());
        assert!(doc.redo());
        assert_eq!(doc.text, "abc");
    }

    #[test]
    fn a_new_edit_after_undo_clears_the_redo_history() {
        let mut doc = Document::untitled(8);
        doc.text = "a".into();
        doc.observed_text.clone_from(&doc.text);

        doc.text.push('b');
        doc.record_text_edit(1, 1, false);
        assert!(doc.undo());
        doc.text.push('c');
        doc.record_text_edit(1, 1, false);

        assert!(!doc.redo());
        assert_eq!(doc.text, "ac");
    }

    #[test]
    fn undoing_back_to_the_saved_text_clears_the_dirty_state() {
        let mut doc = Document::untitled(9);
        doc.text = "saved".into();
        doc.observed_text.clone_from(&doc.text);
        doc.saved_text.clone_from(&doc.text);

        doc.text.push('!');
        doc.record_text_edit(5, 5, false);
        assert!(doc.is_dirty());
        assert!(doc.undo());
        assert!(!doc.is_dirty());
    }

    #[test]
    fn newline_keeps_indentation_and_indents_after_an_open_bracket() {
        let mut doc = Document::untitled(10);
        doc.text = "    fn main() {".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = doc.text.chars().count();
        doc.cursor_anchor = doc.cursor;

        doc.insert_indented_newline("    ");

        assert_eq!(doc.text, "    fn main() {\n        ");
        assert_eq!(doc.cursor, doc.text.chars().count());
        assert!(doc.undo());
        assert_eq!(doc.text, "    fn main() {");
    }

    #[test]
    fn newline_splits_an_empty_bracket_pair_and_keeps_closer_indentation() {
        let mut doc = Document::untitled(11);
        doc.text = "    {}".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = 5;
        doc.cursor_anchor = 5;

        doc.insert_indented_newline("    ");

        assert_eq!(doc.text, "    {\n        \n    }");
        assert_eq!(doc.cursor, 14);
    }

    #[test]
    fn inserting_newline_below_uses_line_end_and_is_undoable() {
        let mut doc = Document::untitled(12);
        doc.text = "  first\nsecond".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = 3;
        doc.cursor_anchor = 3;

        doc.insert_newline_below("    ");

        assert_eq!(doc.text, "  first\n  \nsecond");
        assert_eq!(doc.cursor_byte_offset(), 10);
        assert!(doc.undo());
        assert_eq!(doc.text, "  first\nsecond");
    }

    #[test]
    fn inserting_newline_above_a_closer_adds_one_indent_level() {
        let mut doc = Document::untitled(13);
        doc.text = "    }".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = 4;
        doc.cursor_anchor = 4;

        doc.insert_newline_above("    ");

        assert_eq!(doc.text, "        \n    }");
        assert_eq!(doc.cursor_byte_offset(), 8);
        assert!(doc.undo());
        assert_eq!(doc.text, "    }");
    }

    #[test]
    fn tab_inserts_spaces_to_the_next_indent_stop() {
        let mut doc = Document::untitled(12);
        doc.text = "  text".into();
        doc.observed_text.clone_from(&doc.text);
        doc.cursor = 2;
        doc.cursor_anchor = 2;

        doc.insert_tab_indent("    ", 4, true);

        assert_eq!(doc.text, "    text");
        assert_eq!(doc.cursor, 4);
        assert!(doc.undo());
        assert_eq!(doc.text, "  text");
    }

    #[test]
    fn tab_uses_configured_width_and_can_insert_a_literal_tab() {
        let mut spaces = Document::untitled(1);
        spaces.text = "abc".into();
        spaces.cursor = 3;
        spaces.cursor_anchor = 3;
        spaces.insert_tab_indent("        ", 8, true);
        assert_eq!(spaces.text, "abc     ");

        let mut tabs = Document::untitled(2);
        tabs.text = "abc".into();
        tabs.cursor = 3;
        tabs.cursor_anchor = 3;
        tabs.insert_tab_indent("\t", 8, false);
        assert_eq!(tabs.text, "abc\t");
    }

    #[test]
    fn tab_indents_every_line_in_a_multiline_selection() {
        let mut doc = Document::untitled(13);
        doc.text = "first\nsecond\nthird".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(2, 13);

        doc.insert_tab_indent("    ", 4, true);

        assert_eq!(doc.text, "    first\n    second\nthird");
        assert_eq!(doc.cursor_byte_offset(), 21);
        assert_eq!(doc.cursor_anchor_byte_offset(), 6);
        assert!(doc.undo());
        assert_eq!(doc.text, "first\nsecond\nthird");
    }

    #[test]
    fn tab_indents_selected_lines_with_tabs_when_spaces_are_disabled() {
        let mut doc = Document::untitled(1);
        doc.text = "first\nsecond".into();
        doc.cursor = 12;
        doc.cursor_anchor = 0;

        doc.insert_tab_indent("\t", 8, false);

        assert_eq!(doc.text, "\tfirst\n\tsecond");
    }

    #[test]
    fn outdent_removes_one_indent_unit_from_selected_lines() {
        let mut doc = Document::untitled(14);
        doc.text = "    first\n  second\nthird".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(3, 20);

        doc.outdent_selection(4);

        assert_eq!(doc.text, "first\nsecond\nthird");
        assert!(doc.undo());
        assert_eq!(doc.text, "    first\n  second\nthird");
    }

    #[test]
    fn outdent_does_not_remove_content_from_unindented_lines() {
        let mut doc = Document::untitled(15);
        doc.text = "plain\n  indented".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        doc.outdent_selection(4);

        assert_eq!(doc.text, "plain\nindented");
    }

    #[test]
    fn explicit_indent_indents_nonempty_selected_lines_and_skips_blank_lines() {
        let mut doc = Document::untitled(16);
        doc.text = "first\n\nthird".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        doc.indent_selection("    ");

        assert_eq!(doc.text, "    first\n\n    third");
        assert!(doc.undo());
        assert_eq!(doc.text, "first\n\nthird");
    }

    #[test]
    fn opening_pairs_wrap_selections_and_skip_existing_closers() {
        let mut doc = Document::untitled(17);
        doc.text = "value".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        assert!(doc.type_paired_character('('));
        assert_eq!(doc.text, "(value)");
        assert_eq!((doc.cursor_anchor, doc.cursor), (1, 6));
        assert!(doc.undo());
        assert_eq!(doc.text, "value");

        doc.text = "()".into();
        doc.observed_text.clone_from(&doc.text);
        doc.undo.clear();
        doc.redo.clear();
        doc.set_cursor_byte_offset(1);
        assert!(doc.type_paired_character(')'));
        assert_eq!(doc.text, "()");
        assert_eq!(doc.cursor, 2);
        assert!(doc.undo.is_empty());
    }

    #[test]
    fn quote_pairing_skips_identifier_boundaries() {
        let mut doc = Document::untitled(18);
        doc.text = "word".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_cursor_byte_offset(4);

        assert!(!doc.type_paired_character('"'));
        assert_eq!(doc.text, "word");

        doc.text.push(' ');
        doc.observed_text.clone_from(&doc.text);
        doc.set_cursor_byte_offset(doc.text.len());
        assert!(doc.type_paired_character('"'));
        assert_eq!(doc.text, "word \"\"");
        assert_eq!(doc.cursor, 6);
    }

    #[test]
    fn moving_selected_lines_preserves_selection_and_is_undoable() {
        let mut doc = Document::untitled(20);
        doc.text = "one\n二\nthree".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(4, 7);

        assert!(doc.move_selected_lines(true));
        assert_eq!(doc.text, "one\nthree\n二");
        assert_eq!(
            &doc.text[doc.cursor_anchor_byte_offset()..doc.cursor_byte_offset()],
            "二"
        );
        assert!(doc.undo());
        assert_eq!(doc.text, "one\n二\nthree");
    }

    #[test]
    fn toggle_line_comments_uses_minimum_indent_and_ignores_blank_lines() {
        let mut doc = Document::untitled(1);
        doc.text = "  first\n\n    second".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        assert!(doc.toggle_line_comments("//"));
        assert_eq!(doc.text, "  // first\n\n  //   second");
        assert!(doc.undo());
        assert_eq!(doc.text, "  first\n\n    second");
    }

    #[test]
    fn toggle_line_comments_uncomments_only_when_every_nonblank_line_is_commented() {
        let mut doc = Document::untitled(1);
        doc.text = "  # first\n\n  # second".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        assert!(doc.toggle_line_comments("#"));
        assert_eq!(doc.text, "  first\n\n  second");
        assert!(doc.undo());
        assert_eq!(doc.text, "  # first\n\n  # second");
    }

    #[test]
    fn toggle_line_comments_preserves_unicode_cursor_and_selection() {
        let mut doc = Document::untitled(1);
        doc.text = "café\nnaïve".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        assert!(doc.toggle_line_comments("//"));

        assert_eq!(doc.text, "// café\n// naïve");
        assert_eq!(doc.cursor_anchor_byte_offset(), 3);
        assert_eq!(doc.cursor_byte_offset(), doc.text.len());
    }

    #[test]
    fn select_line_selects_the_current_line_and_extends_on_repeat() {
        let mut doc = Document::untitled(1);
        doc.text = "one\n二\nthree".into();
        doc.cursor = 2;
        doc.cursor_anchor = 2;

        doc.select_line();
        assert_eq!(
            &doc.text[doc.cursor_anchor_byte_offset()..doc.cursor_byte_offset()],
            "one\n"
        );

        doc.select_line();
        assert_eq!(
            &doc.text[doc.cursor_anchor_byte_offset()..doc.cursor_byte_offset()],
            "one\n二\n"
        );
    }

    #[test]
    fn select_line_selects_unicode_line_at_end_of_document() {
        let mut doc = Document::untitled(1);
        doc.text = "one\ncafé".into();
        doc.set_cursor_byte_offset(doc.text.len());

        doc.select_line();

        assert_eq!(
            &doc.text[doc.cursor_anchor_byte_offset()..doc.cursor_byte_offset()],
            "café"
        );
    }

    #[test]
    fn duplicate_selected_lines_places_the_copy_after_the_block() {
        let mut doc = Document::untitled(21);
        doc.text = "one\ntwo\nthree".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, 7);

        doc.duplicate_selected_lines();

        assert_eq!(doc.text, "one\ntwo\none\ntwo\nthree");
        assert!(doc.undo());
        assert_eq!(doc.text, "one\ntwo\nthree");
    }

    #[test]
    fn deleting_selected_lines_keeps_a_valid_empty_document_and_is_undoable() {
        let mut doc = Document::untitled(22);
        doc.text = "one\ntwo".into();
        doc.observed_text.clone_from(&doc.text);
        doc.set_selection_byte_offsets(0, doc.text.len());

        doc.delete_selected_lines();

        assert!(doc.text.is_empty());
        assert_eq!(doc.cursor, 0);
        assert!(doc.undo());
        assert_eq!(doc.text, "one\ntwo");
    }
}
