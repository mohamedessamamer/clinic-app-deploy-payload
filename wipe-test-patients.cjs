#!/usr/bin/env node
// سكريبت صيانة لمرة واحدة — بيمسح كل بيانات المرضى (الملفات الطبية والمالية)
// نهائيًا من قاعدة البيانات، من غير ما يلمس أي حاجة تانية (الأطباء، المستخدمين،
// الصلاحيات، الخدمات، العيادات/الغرف، الشيفتات، الإعدادات، سجل التعديلات).
//
// السكوب: بيمسح patients + visits + invoices + appointments + patient_image_groups
// + patient_images (وملفات الصور الفعلية من على القرص) — بالظبط نفس السكوب اللي
// بيمسحه زرار "حذف الحالة" الموجود بالفعل في النظام (deletePatientAction، دفعة 12)
// بس مطبّق على كل المرضى مرة واحدة بدل واحد واحد.
//
// الاستخدام (من داخل /opt/clinic-app على السيرفر):
//   node wipe-test-patients.cjs           -> بس بيعرض إيه اللي هيتمسح (dry run)
//   node wipe-test-patients.cjs --confirm -> بيمسح فعليًا (بعد تأكيد إضافي بالكتابة)
"use strict";

const path = require("path");
const fs = require("fs");
const readline = require("readline");

const DB_PATH = process.env.CLINIC_DB_PATH || path.join(process.cwd(), "data", "clinic.db");
const UPLOAD_ROOT = process.env.CLINIC_UPLOAD_DIR
  ? path.join(path.resolve(process.env.CLINIC_UPLOAD_DIR), "patients")
  : path.join(process.cwd(), "data", "uploads", "patients");

if (!fs.existsSync(DB_PATH)) {
  console.error(`قاعدة البيانات مش موجودة في: ${DB_PATH}`);
  process.exit(1);
}

const Database = require("better-sqlite3");
const db = new Database(DB_PATH);
db.pragma("foreign_keys = ON");

function count(table) {
  return db.prepare(`SELECT COUNT(*) AS c FROM ${table}`).get().c;
}

const before = {
  patients: count("patients"),
  visits: count("visits"),
  invoices: count("invoices"),
  appointments: count("appointments"),
  patient_image_groups: count("patient_image_groups"),
  patient_images: count("patient_images"),
};

const untouched = {
  doctors: count("doctors"),
  users: count("users"),
  services: count("services"),
};

console.log("== البيانات اللي هتتمسح (لو أكّدت) ==");
console.log(before);
console.log("== البيانات دي مش هتتلمس خالص ==");
console.log(untouched);

const patientNames = db.prepare("SELECT id, full_name FROM patients ORDER BY id").all();
if (patientNames.length > 0) {
  console.log("\nقايمة المرضى اللي هيتمسحوا:");
  for (const p of patientNames) console.log(`  #${p.id} - ${p.full_name}`);
}

if (before.patients === 0) {
  console.log("\nمفيش مرضى في قاعدة البيانات أصلاً — مفيش حاجة تتمسح.");
  process.exit(0);
}

const isConfirmRun = process.argv.includes("--confirm");

if (!isConfirmRun) {
  console.log(
    "\n== ده عرض بس (dry run) — مفيش حاجة اتمسحت. لو الأرقام والقايمة فوق صح، شغّل: node wipe-test-patients.cjs --confirm =="
  );
  process.exit(0);
}

// تأكيد إضافي حقيقي جوه السكريبت نفسه، حتى بعد --confirm، عشان مفيش حذف بالغلط
// من ضغطة واحدة غلط.
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.question('\nاكتب "امسح" بالظبط وادوس Enter عشان تأكد الحذف النهائي (أي حاجة تانية = إلغاء): ', (answer) => {
  rl.close();
  if (answer.trim() !== "امسح") {
    console.log("اتلغى — مفيش حاجة اتمسحت.");
    process.exit(0);
  }
  runDelete();
});

function runDelete() {
  // نجيب مسارات ملفات الصور الأول قبل ما نمسح صفوفها من قاعدة البيانات.
  const imagePaths = db
    .prepare(
      `SELECT patient_images.file_path AS file_path
       FROM patient_images
       INNER JOIN patient_image_groups ON patient_image_groups.id = patient_images.group_id`
    )
    .all()
    .map((r) => r.file_path);

  const tx = db.transaction(() => {
    db.prepare("UPDATE invoices SET parent_invoice_id = NULL").run();
    db.prepare("DELETE FROM patient_images").run();
    db.prepare("DELETE FROM patient_image_groups").run();
    db.prepare("DELETE FROM invoices").run();
    db.prepare("DELETE FROM visits").run();
    db.prepare("DELETE FROM appointments").run();
    db.prepare("DELETE FROM patients").run();
  });
  tx();

  let deletedFiles = 0;
  let missingFiles = 0;
  for (const filePath of imagePaths) {
    if (!filePath.startsWith("/patient-files/")) continue;
    const relative = filePath.replace(/^\/patient-files\//, "");
    const diskPath = path.join(path.dirname(UPLOAD_ROOT), relative);
    try {
      fs.unlinkSync(diskPath);
      deletedFiles++;
    } catch (e) {
      missingFiles++;
    }
  }

  const after = {
    patients: count("patients"),
    visits: count("visits"),
    invoices: count("invoices"),
    appointments: count("appointments"),
    patient_image_groups: count("patient_image_groups"),
    patient_images: count("patient_images"),
  };
  const untouchedAfter = {
    doctors: count("doctors"),
    users: count("users"),
    services: count("services"),
  };

  console.log("\n== تم الحذف ==");
  console.log("بعد الحذف (المفروض كله صفر):", after);
  console.log("اتأكد ما اتأثرش (لازم يكون زي قبل):", untouchedAfter);
  console.log(`ملفات صور اتمسحت من على القرص: ${deletedFiles} (ملفات مش لاقيها أصلاً/اتجاهلت: ${missingFiles})`);
}
