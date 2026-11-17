// SQLite store shared by both networks, plus an event bus the WebSocket clients listen to.
import { DatabaseSync } from 'node:sqlite'
import { EventEmitter } from 'node:events'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

export const DATA = process.env.DATA_DIR || './data'
for (const dir of ['media', 'avatars']) fs.mkdirSync(path.join(DATA, dir), { recursive: true })

export const bus = new EventEmitter()
export const httpError = (status, message) => Object.assign(new Error(message), { status })
export const sha1 = s => crypto.createHash('sha1').update(s).digest('hex')

const db = new DatabaseSync(path.join(DATA, 'convo.db'))
db.exec(`
  CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY, network TEXT NOT NULL, name TEXT, is_group INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0, last_ts INTEGER NOT NULL DEFAULT 0,
    last_text TEXT NOT NULL DEFAULT '', last_sender TEXT NOT NULL DEFAULT '', last_from_me INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, from_me INTEGER NOT NULL, sender TEXT NOT NULL,
    text TEXT NOT NULL, ts INTEGER NOT NULL, media TEXT
  );
  CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages (chat_id, ts);
  CREATE TABLE IF NOT EXISTS reactions (
    message_id TEXT NOT NULL, sender TEXT NOT NULL, emoji TEXT NOT NULL, PRIMARY KEY (message_id, sender)
  );
  CREATE TABLE IF NOT EXISTS votes (
    message_id TEXT NOT NULL, voter TEXT NOT NULL, options TEXT NOT NULL, PRIMARY KEY (message_id, voter)
  );
`)
// Columns added after the first release. poll: {question, options, multi}. ref: network data needed to
// react, vote or download media later; it stays on the bridge. phone: "+<digits>" when the id doesn't show it.
// sender_id: "wa:<jid>" or "sg:<number|uuid>" of who sent a message, for their picture and contact name.
for (const [table, column] of [['messages', 'poll'], ['messages', 'ref'], ['messages', 'sender_id'], ['chats', 'phone']]) {
  if (!db.prepare(`SELECT 1 FROM pragma_table_info('${table}') WHERE name = ?`).get(column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} TEXT`)
  }
}

// Sender/voter "me" is the account owner.
export const ME = 'me'

// Chat ids are "wa:<jid>" or "sg:<number|uuid|group.id>". The phone number lets the app use the iPhone's
// contact names; it is also the name shown when we know none.
function phoneOf(r) {
  if (r.phone) return r.phone
  const addr = r.id.slice(3)
  if (r.id.startsWith('wa:') && addr.endsWith('@s.whatsapp.net')) return '+' + addr.split('@')[0]
  if (r.id.startsWith('sg:') && /^\+\d+$/.test(addr)) return addr
  return null
}
const toChat = r => r && ({
  id: r.id, network: r.network, name: r.name || (r.is_group ? 'Group' : phoneOf(r) || r.id.slice(3)),
  phone: r.is_group ? null : phoneOf(r), isGroup: !!r.is_group,
  unread: r.unread, lastTs: r.last_ts, lastText: r.last_text, lastSender: r.last_sender, lastFromMe: !!r.last_from_me,
})
function toMessage(r) {
  if (!r) return r
  const message = {
    id: r.id, chatId: r.chat_id, fromMe: !!r.from_me, sender: r.sender, senderId: r.sender_id || '', text: r.text, ts: r.ts, media: r.media,
    reactions: db.prepare('SELECT sender, emoji FROM reactions WHERE message_id = ?').all(r.id)
      .map(x => ({ emoji: x.emoji, fromMe: x.sender === ME })),
    poll: null,
  }
  if (r.poll) {
    const { question, options, multi } = JSON.parse(r.poll)
    const votes = db.prepare('SELECT voter, options FROM votes WHERE message_id = ?').all(r.id)
      .map(v => ({ mine: v.voter === ME, picked: JSON.parse(v.options) }))
    message.poll = {
      question, multi,
      options: options.map(name => ({
        name, votes: votes.filter(v => v.picked.includes(name)).length,
        mine: votes.some(v => v.mine && v.picked.includes(name)),
      })),
    }
  }
  return message
}

export const getChat = id => toChat(db.prepare('SELECT * FROM chats WHERE id = ?').get(id))
export const getMessage = id => toMessage(db.prepare('SELECT * FROM messages WHERE id = ?').get(id))
export const getRef = id => db.prepare('SELECT ref FROM messages WHERE id = ?').get(id)?.ref ?? null
export const messageAt = (chatId, ts) => toMessage(db.prepare('SELECT * FROM messages WHERE chat_id = ? AND ts = ?').get(chatId, ts))
export const listChats = () => db.prepare('SELECT * FROM chats ORDER BY last_ts DESC').all().map(toChat)

export function listMessages(chatId, before = Number.MAX_SAFE_INTEGER, limit = 60) {
  return db.prepare('SELECT * FROM messages WHERE chat_id = ? AND ts < ? ORDER BY ts DESC LIMIT ?')
    .all(chatId, before, limit).map(toMessage).reverse()
}

// Creates the chat if needed; a name given here only fills in a missing one.
export function ensureChat(id, network, { name = null, isGroup = false } = {}) {
  db.prepare(`INSERT INTO chats (id, network, name, is_group) VALUES (?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET name = COALESCE(chats.name, excluded.name)`).run(id, network, name || null, isGroup ? 1 : 0)
}

export const chatIdsLike = pattern => db.prepare('SELECT id FROM chats WHERE id LIKE ? AND phone IS NULL').all(pattern).map(r => r.id)
export function setPhone(id, phone) {
  if (db.prepare('UPDATE chats SET phone = ? WHERE id = ?').run(phone, id).changes) bus.emit('chat', getChat(id))
}

// Authoritative name (address book, group subject). Only touches chats that exist.
export function renameChat(id, name) {
  if (!name) return
  if (db.prepare('UPDATE chats SET name = ? WHERE id = ? AND name IS NOT ?').run(name, id, name).changes) {
    bus.emit('chat', getChat(id))
  }
}

export function markRead(id) {
  db.prepare('UPDATE chats SET unread = 0 WHERE id = ?').run(id)
  const chat = getChat(id)
  bus.emit('chat', chat)
  return chat
}

// live = a new message (counts as unread, pushed to clients). History imports pass live: false.
export function addMessage(m, { live = true } = {}) {
  const inserted = db.prepare(`INSERT OR IGNORE INTO messages (id, chat_id, from_me, sender, text, ts, media, poll, ref, sender_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(m.id, m.chatId, m.fromMe ? 1 : 0, m.sender || '', m.text || '', m.ts,
    m.media || null, m.poll ? JSON.stringify(m.poll) : null, m.ref || null, m.senderId || null).changes
  if (!inserted) return null
  const last = m.text || (m.poll ? '📊 ' + m.poll.question : m.media ? '📷 Photo' : '')
  db.prepare(`UPDATE chats SET last_ts = ?, last_text = ?, last_sender = ?, last_from_me = ? WHERE id = ? AND last_ts <= ?`)
    .run(m.ts, last, m.sender || '', m.fromMe ? 1 : 0, m.chatId, m.ts)
  if (live) db.prepare(`UPDATE chats SET unread = ${m.fromMe ? '0' : 'unread + 1'} WHERE id = ?`).run(m.chatId)
  const message = getMessage(m.id)
  if (live) bus.emit('message', { chat: getChat(m.chatId), message })
  return message
}

// Reactions and votes may arrive before their message; they show once it does. An empty emoji removes it.
export function react(messageId, sender, emoji, { live = true } = {}) {
  if (emoji) {
    db.prepare('INSERT INTO reactions VALUES (?, ?, ?) ON CONFLICT DO UPDATE SET emoji = excluded.emoji').run(messageId, sender, emoji)
  } else {
    db.prepare('DELETE FROM reactions WHERE message_id = ? AND sender = ?').run(messageId, sender)
  }
  return changed(messageId, live)
}

export function vote(messageId, voter, options, { live = true } = {}) {
  if (options.length) {
    db.prepare('INSERT INTO votes VALUES (?, ?, ?) ON CONFLICT DO UPDATE SET options = excluded.options')
      .run(messageId, voter, JSON.stringify(options))
  } else {
    db.prepare('DELETE FROM votes WHERE message_id = ? AND voter = ?').run(messageId, voter)
  }
  return changed(messageId, live)
}

function changed(messageId, live) {
  const message = getMessage(messageId)
  if (message && live) bus.emit('update', { chat: getChat(message.chatId), message })
  return message
}

export const mediaPath = messageId => path.join(DATA, 'media', sha1(messageId))
export const saveMedia = (messageId, buffer) => fs.writeFileSync(mediaPath(messageId), buffer)
