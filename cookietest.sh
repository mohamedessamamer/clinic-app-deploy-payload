#!/bin/bash
cd /tmp
rm -f login.html cookies.txt headers1.txt headers2.txt after_login.html patients.html

echo "=== fetching /login ==="
curl -s -c cookies.txt -o login.html http://127.0.0.1/login
ACTION_FIELD=$(grep -oE '\$ACTION_ID_[a-f0-9]+' login.html | head -1)
echo "ACTION_FIELD=$ACTION_FIELD"

echo "=== submitting login form ==="
curl -s -D headers1.txt -o after_login.html -c cookies.txt -b cookies.txt \
  -F "username=admin" \
  -F "password=admin123" \
  -F "next=/" \
  -F "${ACTION_FIELD}=" \
  http://127.0.0.1/login

echo "=== LOGIN RESPONSE HEADERS ==="
cat headers1.txt

echo "=== COOKIE JAR AFTER LOGIN ==="
cat cookies.txt

echo "=== FOLLOWUP GET /patients WITH SAME COOKIE JAR ==="
curl -s -D headers2.txt -o patients.html -b cookies.txt http://127.0.0.1/patients
cat headers2.txt

echo "=== FOLLOWUP GET / WITH SAME COOKIE JAR ==="
curl -s -D headers3.txt -o root.html -b cookies.txt http://127.0.0.1/
cat headers3.txt

echo "COOKIETEST_COMPLETE"
