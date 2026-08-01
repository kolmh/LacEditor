const url = "https://example.com"; // 这一段是注释
const pattern = /https?:\/\//;
const csvEscape = (value) => {
  const text = String(value);
  if (/[",\n\r]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
  return text;
};

const active = true;
