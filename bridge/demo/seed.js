// Fills an empty bridge database with the chats from the HTML example, for screenshots.
// Usage: DATA_DIR=/tmp/convo-demo node demo/seed.js
import fs from 'node:fs'
import path from 'node:path'
import * as store from '../src/store.js'

const photos = new URL('../../photos/', import.meta.url)
const photo = name => fs.readFileSync(new URL(`${name}.jpg`, photos))
const now = Date.now(), H = 60, D = 1440

const chats = [
  ['wa:120363000000000001@g.us', 'The Boys', 'tim', [['Tim', 'This is gonna be crazy 😂', 5], ['me', "Can't wait!", 4], ['Martijn', "Who's bringing the snacks?", 3], ['me', 'I got it covered 😌', 2.5], ['Max', 'Legend', 2.2], ['Martijn', '🔥🔥', 1.8], ['Tim', '', 1, 'sunset']], true],
  ['wa:31600000002@s.whatsapp.net', 'Sophie', 'sophie', [['me', 'Thanks for tonight!', 50], ['Sophie', 'See you later!', 45]]],
  ['sg:group.c3R1ZHlncm91cA==', 'Study Group', null, [['Lotte', 'Who has the slides from Monday?', 2.2 * H], ['Martijn', "I'll send the notes", 2.1 * H]], true],
  ['wa:31600000004@s.whatsapp.net', 'Max', 'max', [['me', 'Finally fixed my bike', 3 * H], ['Max', 'Haha nice!', 2.7 * H]]],
  ['wa:31600000005@s.whatsapp.net', 'Lotte', 'lotte', [['me', 'Coffee at 10 tomorrow?', 3.4 * H], ['Lotte', 'Sounds good 👍', 3.3 * H]]],
  ['wa:120363000000000006@g.us', 'Family', null, [['Mom', 'Dinner at 7?', D]]],
  ['sg:+31600000007', 'Thomas', null, [['me', "I'll pick you up at 8", D + 60], ['Thomas', 'Perfect!', D + 50]]],
]

for (const [id, name, avatar, messages, unread] of chats) {
  const network = id.startsWith('wa:') ? 'whatsapp' : 'signal'
  const isGroup = id.endsWith('@g.us') || id.startsWith('sg:group.')
  store.ensureChat(id, network, { name, isGroup })
  if (avatar) fs.writeFileSync(path.join(store.DATA, 'avatars', store.sha1(id)), photo(avatar))
  messages.forEach(([who, text, minutesAgo, image], i) => {
    const m = { id: `${id}/demo${i}`, chatId: id, fromMe: who === 'me', sender: who === 'me' ? '' : who, text, ts: now - minutesAgo * 60000 }
    if (image) { m.media = 'image/jpeg'; store.saveMedia(m.id, photo(image)) }
    store.addMessage(m, { live: !!unread })
  })
}
console.log(`Seeded ${chats.length} chats into ${store.DATA}`)
