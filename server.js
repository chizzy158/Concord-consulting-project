require('dotenv').config();
const express   = require('express');
const helmet    = require('helmet');
const rateLimit = require('express-rate-limit');
const mysql     = require('mysql2/promise');
const validator = require('validator');
const path      = require('path');

const app  = express();
const PORT = process.env.PORT || 3000;

/* ──────────────────────────────────────
   SECURITY MIDDLEWARE
────────────────────────────────────── */
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc:  ["'self'", "'unsafe-inline'", "fonts.googleapis.com", "cdn-cgi"],
      styleSrc:   ["'self'", "'unsafe-inline'", "fonts.googleapis.com"],
      fontSrc:    ["'self'", "fonts.gstatic.com"],
      imgSrc:     ["'self'", "data:", "https:"],
    }
  }
}));

app.use(express.json({ limit: '10kb' }));
app.use(express.urlencoded({ extended: true, limit: '10kb' }));

// Rate limit the contact form — max 10 submissions per 15 min per IP
const contactLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  message: { error: 'Too many requests, please try again later.' }
});

/* ──────────────────────────────────────
   DATABASE CONNECTION POOL
────────────────────────────────────── */
const pool = mysql.createPool({
  host:     process.env.DB_HOST,
  user:     process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  port:     process.env.DB_PORT || 3306,
  waitForConnections: true,
  connectionLimit:    10,
});

/* ──────────────────────────────────────
   INIT DATABASE TABLE
────────────────────────────────────── */
async function initDB() {
  const conn = await pool.getConnection();
  await conn.execute(`
    CREATE TABLE IF NOT EXISTS contacts (
      id         INT AUTO_INCREMENT PRIMARY KEY,
      name       VARCHAR(120)  NOT NULL,
      email      VARCHAR(200)  NOT NULL,
      phone      VARCHAR(30),
      company    VARCHAR(120),
      service    VARCHAR(80)   NOT NULL,
      message    TEXT          NOT NULL,
      ip_address VARCHAR(45),
      created_at TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
    )
  `);
  conn.release();
  console.log('✅  Database table ready');
}

/* ──────────────────────────────────────
   SERVE STATIC FILES (your HTML site)
────────────────────────────────────── */
app.use(express.static(path.join(__dirname, 'public')));

/* ──────────────────────────────────────
   HEALTH CHECK (used by CI/CD + ALB)
────────────────────────────────────── */
app.get('/health', async (req, res) => {
  try {
    const conn = await pool.getConnection();
    conn.release();
    res.json({ status: 'ok', db: 'connected', timestamp: new Date().toISOString() });
  } catch {
    res.status(503).json({ status: 'error', db: 'unreachable' });
  }
});

/* ──────────────────────────────────────
   CONTACT FORM API
────────────────────────────────────── */
app.post('/api/contact', contactLimiter, async (req, res) => {
  const { name, email, phone, company, service, message } = req.body;

  // --- Input validation ---
  if (!name   || !validator.isLength(name.trim(),   { min: 2, max: 120 }))
    return res.status(400).json({ error: 'Invalid name.' });
  if (!email  || !validator.isEmail(email))
    return res.status(400).json({ error: 'Invalid email address.' });
  if (!service || !validator.isLength(service.trim(), { min: 1, max: 80 }))
    return res.status(400).json({ error: 'Please select a service.' });
  if (!message || !validator.isLength(message.trim(), { min: 5, max: 2000 }))
    return res.status(400).json({ error: 'Message must be between 5 and 2000 characters.' });

  // --- Sanitise ---
  const safe = {
    name:    validator.escape(name.trim()),
    email:   validator.normalizeEmail(email),
    phone:   phone   ? validator.escape(phone.trim())   : null,
    company: company ? validator.escape(company.trim()) : null,
    service: validator.escape(service.trim()),
    message: validator.escape(message.trim()),
    ip:      req.ip
  };

  try {
    await pool.execute(
      `INSERT INTO contacts (name, email, phone, company, service, message, ip_address)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [safe.name, safe.email, safe.phone, safe.company, safe.service, safe.message, safe.ip]
    );
    console.log(`📩  New contact submission from ${safe.email}`);
    res.json({ success: true, message: 'Your message has been received!' });
  } catch (err) {
    console.error('DB insert error:', err.message);
    res.status(500).json({ error: 'Failed to save your message. Please try again.' });
  }
});

/* ──────────────────────────────────────
   FALLBACK — serve index.html for any
   unmatched route (SPA-style routing)
────────────────────────────────────── */
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

/* ──────────────────────────────────────
   START SERVER
────────────────────────────────────── */
initDB()
  .then(() => {
    app.listen(PORT, () => console.log(`🚀  Concord server running on port ${PORT}`));
  })
  .catch(err => {
    console.error('❌  Failed to initialise DB:', err.message);
    process.exit(1);
  });

module.exports = app;
