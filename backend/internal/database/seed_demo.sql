-- Realistic demo data across all portals, spread over a believable timeline.
-- Idempotent: guarded by a sentinel lead, so re-running won't duplicate.
-- Ties data to the test users (admin@/ambassador@/franchise@/employee@onrol.test).
-- API-backed features (WhatsApp/Razorpay/email) stay in demo mode.

DO $$
DECLARE
  adm uuid; amb uuid; fr uuid; emp uuid;
  lead_aarav uuid; lead_isha uuid; lead_rohan uuid; lead_neha uuid; lead_vikram uuid;
  acc_acme uuid; acc_zen uuid; acc_nova uuid;
  inv1 uuid; inv2 uuid; inv3 uuid;
  aff1 uuid; aff2 uuid;
  col1 uuid; col2 uuid;
  srv1 uuid; frm1 uuid;
BEGIN
  SELECT id INTO adm FROM users WHERE email='admin@onrol.test';
  SELECT id INTO amb FROM users WHERE email='ambassador@onrol.test';
  SELECT id INTO fr  FROM users WHERE email='franchise@onrol.test';
  SELECT id INTO emp FROM users WHERE email='employee@onrol.test';

  IF EXISTS (SELECT 1 FROM leads WHERE email='aarav.sharma@example.com') THEN
    RAISE NOTICE 'demo data already seeded — skipping';
    RETURN;
  END IF;

  -- ===== CRM: Leads (spread over ~6 weeks, varied stages) =====
  INSERT INTO leads (name, phone, email, source, campaign, status, assigned_counsellor, score, notes, created_at, updated_at) VALUES
    ('Aarav Sharma','+91 90000 11111','aarav.sharma@example.com','Webinar','May Cohort','Converted','Priya',88,'Joined Full-Stack batch', now()-interval '41 days', now()-interval '3 days'),
    ('Isha Patel','+91 90000 22222','isha.patel@example.com','Instagram','May Cohort','Payment Pending','Priya',74,'Awaiting fee payment', now()-interval '33 days', now()-interval '1 day'),
    ('Rohan Mehta','+91 90000 33333','rohan.mehta@example.com','Referral','','Interested','Karthik',61,'Wants weekend batch', now()-interval '27 days', now()-interval '2 days'),
    ('Neha Verma','+91 90000 44444','neha.verma@example.com','Website','','Attended','Karthik',55,'Attended demo class', now()-interval '20 days', now()-interval '4 days'),
    ('Vikram Singh','+91 90000 55555','vikram.singh@example.com','Google Ads','','Registered','Priya',48,'', now()-interval '14 days', now()-interval '5 days'),
    ('Ananya Iyer','+91 90000 66666','ananya.iyer@example.com','Webinar','June Cohort','New Lead','',30,'', now()-interval '9 days', now()-interval '9 days'),
    ('Kabir Nair','+91 90000 77777','kabir.nair@example.com','Referral','','New Lead','',25,'', now()-interval '6 days', now()-interval '6 days'),
    ('Diya Reddy','+91 90000 88888','diya.reddy@example.com','Instagram','','Not Attended','Karthik',20,'No-show for demo', now()-interval '4 days', now()-interval '4 days'),
    ('Arjun Gupta','+91 90000 99999','arjun.gupta@example.com','Website','June Cohort','Interested','Priya',58,'Comparing with competitor', now()-interval '3 days', now()-interval '1 day'),
    ('Meera Joshi','+91 90001 00000','meera.joshi@example.com','Webinar','June Cohort','New Lead','',22,'', now()-interval '1 day', now()-interval '1 day');

  SELECT id INTO lead_aarav FROM leads WHERE email='aarav.sharma@example.com';
  SELECT id INTO lead_isha  FROM leads WHERE email='isha.patel@example.com';
  SELECT id INTO lead_rohan FROM leads WHERE email='rohan.mehta@example.com';
  SELECT id INTO lead_neha  FROM leads WHERE email='neha.verma@example.com';
  SELECT id INTO lead_vikram FROM leads WHERE email='vikram.singh@example.com';

  -- Activities timeline
  INSERT INTO lead_activities (lead_id, type, direction, status, subject, message, created_by, created_at) VALUES
    (lead_aarav,'call','outbound','logged','Intro call','Explained curriculum + fees', adm, now()-interval '40 days'),
    (lead_aarav,'whatsapp','outbound','sent','Brochure','Sent course brochure', adm, now()-interval '39 days'),
    (lead_aarav,'note','internal','logged','','Confirmed enrollment', adm, now()-interval '4 days'),
    (lead_isha,'call','outbound','logged','Follow-up','Discussed payment options', adm, now()-interval '30 days'),
    (lead_isha,'email','outbound','sent','Fee details','Sent fee structure + EMI', adm, now()-interval '12 days'),
    (lead_rohan,'whatsapp','outbound','sent','Weekend batch','Shared weekend schedule', adm, now()-interval '20 days'),
    (lead_neha,'call','outbound','logged','Demo invite','Invited to Saturday demo', adm, now()-interval '18 days'),
    (lead_vikram,'note','internal','logged','','Registered via Google Ads', adm, now()-interval '14 days');

  -- Tasks (overdue / today / upcoming for My Day)
  INSERT INTO lead_tasks (lead_id, assigned_counsellor, title, due_at, status, priority, created_at, updated_at) VALUES
    (lead_isha,'Priya','Collect pending payment', now()-interval '2 days','open','high', now()-interval '5 days', now()-interval '5 days'),
    (lead_rohan,'Karthik','Call about weekend batch', now()-interval '1 day','open','normal', now()-interval '3 days', now()-interval '3 days'),
    (lead_neha,'Karthik','Send recording of demo', now(),'open','normal', now()-interval '1 day', now()-interval '1 day'),
    (lead_vikram,'Priya','Onboarding call', now()+interval '1 day','open','normal', now()-interval '1 day', now()-interval '1 day'),
    (lead_aarav,'Priya','Welcome + Slack invite', now()+interval '2 days','open','normal', now(), now());

  -- ===== CRM: Accounts (companies) =====
  INSERT INTO accounts (name, domain, industry, size_band, arr_paise, health, notes, owner_user_id, created_at, updated_at) VALUES
    ('Acme Corp','acme.com','SaaS','51-200', 1200000000,'healthy','Annual corporate training', adm, now()-interval '60 days', now()-interval '5 days'),
    ('Zen Industries','zenind.com','Manufacturing','201-1000', 600000000,'at_risk','Renewal due next quarter', adm, now()-interval '45 days', now()-interval '10 days'),
    ('Nova Labs','novalabs.io','EdTech','11-50', 300000000,'healthy','Upskilling 20 engineers', adm, now()-interval '20 days', now()-interval '2 days');
  SELECT id INTO acc_acme FROM accounts WHERE name='Acme Corp';
  SELECT id INTO acc_zen  FROM accounts WHERE name='Zen Industries';
  SELECT id INTO acc_nova FROM accounts WHERE name='Nova Labs';

  -- ===== CRM: Deals =====
  INSERT INTO deals (lead_id, account_id, title, value_paise, stage, status, probability, owner_user_id, notes, created_at, updated_at) VALUES
    (NULL, acc_acme,'Acme — 40-seat training', 1500000000,'Closing','open',80, adm,'Final approval pending', now()-interval '30 days', now()-interval '2 days'),
    (NULL, acc_zen, 'Zen — renewal', 600000000,'Negotiation','open',55, adm,'Negotiating discount', now()-interval '25 days', now()-interval '3 days'),
    (NULL, acc_nova,'Nova — 20-seat bootcamp', 400000000,'Proposal','open',60, adm,'Proposal sent', now()-interval '12 days', now()-interval '1 day'),
    (lead_aarav, NULL,'Aarav — Full-Stack fee', 9900000,'Closing','won',100, adm,'Paid in full', now()-interval '38 days', now()-interval '4 days'),
    (lead_rohan, NULL,'Rohan — Weekend batch', 8900000,'Qualification','open',40, adm,'', now()-interval '18 days', now()-interval '2 days');

  -- ===== CRM: Invoices + Payments =====
  INSERT INTO invoices (lead_id, account_id, status, notes, subtotal, tax_rate, tax_amount, total, due_date, sent_at, paid_at, created_by, created_at, updated_at) VALUES
    (lead_aarav, NULL,'paid','Full-Stack course fee', 8389831, 18, 1510169, 9900000, (now()-interval '35 days')::date, now()-interval '38 days', now()-interval '36 days', adm, now()-interval '38 days', now()-interval '36 days'),
    (NULL, acc_acme,'sent','40-seat corporate training', 12711864, 18, 2288136, 15000000, (now()+interval '5 days')::date, now()-interval '6 days', NULL, adm, now()-interval '6 days', now()-interval '6 days'),
    (lead_isha, NULL,'draft','Data Science fee', 7542373, 18, 1357627, 8900000, (now()+interval '10 days')::date, NULL, NULL, adm, now()-interval '2 days', now()-interval '2 days');
  SELECT id INTO inv1 FROM invoices WHERE notes='Full-Stack course fee';
  SELECT id INTO inv2 FROM invoices WHERE notes='40-seat corporate training';
  INSERT INTO payments (lead_id, invoice_id, amount, status, provider, provider_payment_id, created_at) VALUES
    (lead_aarav, inv1, 9900000,'captured','manual','demo_txn_001', now()-interval '36 days');

  -- ===== CRM: Campaigns =====
  INSERT INTO broadcasts (name, channel, subject, body, status, sent_at, total_targets, total_sent, created_by, created_at, updated_at) VALUES
    ('June cohort launch','email','Doors open for June','Enrol now for the June Full-Stack cohort.','sent', now()-interval '10 days', 320, 320, adm, now()-interval '11 days', now()-interval '10 days'),
    ('Fee reminder','whatsapp','','Reminder: complete your enrolment payment.','sent', now()-interval '4 days', 28, 28, adm, now()-interval '4 days', now()-interval '4 days'),
    ('Webinar invite','email','Free live webinar Saturday','Join our free career webinar this Saturday.','draft', NULL, 0, 0, adm, now()-interval '1 day', now()-interval '1 day');

  -- ===== CRM: Surveys + responses =====
  INSERT INTO surveys (slug, title, questions, enabled, created_at) VALUES
    ('post-demo','Post-demo feedback','["How was the demo?","Likelihood to enrol (1-10)","Comments"]', true, now()-interval '25 days');
  SELECT id INTO srv1 FROM surveys WHERE slug='post-demo';
  INSERT INTO survey_responses (survey_id, answers, created_at) VALUES
    (srv1,'{"How was the demo?":"Excellent","Likelihood to enrol (1-10)":"9"}', now()-interval '20 days'),
    (srv1,'{"How was the demo?":"Good","Likelihood to enrol (1-10)":"7"}', now()-interval '12 days');

  -- ===== CRM: Reviews =====
  INSERT INTO reviews (author, rating, body, status, created_at) VALUES
    ('Aarav Sharma',5,'Brilliant mentors and real projects. Got placed!','approved', now()-interval '5 days'),
    ('Sneha R.',5,'Loved the live classes and doubt support.','approved', now()-interval '12 days'),
    ('Anonymous',4,'Good content, would like more assignments.','pending', now()-interval '2 days');

  -- ===== CRM: Calendar events =====
  INSERT INTO crm_events (title, starts_at, kind, notes, created_by, created_at) VALUES
    ('Free career webinar', now()+interval '3 days','webinar','Top-of-funnel event', adm, now()-interval '5 days'),
    ('June cohort kickoff', now()+interval '10 days','class','Orientation', adm, now()-interval '3 days'),
    ('Team review', now()+interval '1 day','meeting','Weekly pipeline review', adm, now()-interval '1 day');

  -- ===== CRM: Newsfeed =====
  INSERT INTO feed_posts (author_id, body, created_at) VALUES
    (adm,'🎉 Aarav just converted — 40th enrolment this month!', now()-interval '4 days'),
    (adm,'Reminder: June cohort starts in 10 days. Push pending payments.', now()-interval '2 days');

  -- ===== CRM: Tickets =====
  INSERT INTO tickets (subject, body, status, priority, lead_id, created_by, created_at, updated_at) VALUES
    ('Cannot access course portal','Student reports login issue','open','high', lead_aarav, adm, now()-interval '2 days', now()-interval '2 days'),
    ('Invoice correction','GST number update requested','pending','normal', NULL, adm, now()-interval '4 days', now()-interval '3 days'),
    ('Refund query','Asked about refund policy','closed','low', NULL, adm, now()-interval '15 days', now()-interval '14 days');

  -- ===== CRM: Webhooks =====
  INSERT INTO webhooks (url, event, enabled, created_at) VALUES
    ('https://hooks.example.com/onrol/lead','lead.created', true, now()-interval '20 days');

  -- ===== CRM: Affiliates + commissions =====
  INSERT INTO affiliates (name, email, code, commission_rate, status, created_at) VALUES
    ('Growth Partners','hello@growthpartners.in','GROWTH10', 10, 'active', now()-interval '50 days'),
    ('EduRefer','team@edurefer.com','EDU15', 15, 'active', now()-interval '30 days');
  SELECT id INTO aff1 FROM affiliates WHERE code='GROWTH10';
  SELECT id INTO aff2 FROM affiliates WHERE code='EDU15';
  INSERT INTO commissions (affiliate_id, amount, status, note, created_at) VALUES
    (aff1, 990000,'paid','Aarav enrolment', now()-interval '34 days'),
    (aff1, 890000,'pending','Rohan (in progress)', now()-interval '10 days'),
    (aff2, 1335000,'pending','2 referrals June', now()-interval '8 days');

  -- ===== CRM: Automation rules =====
  INSERT INTO automation_rules (name, trigger_status, action, action_value, delay_hours, enabled, created_at, updated_at) VALUES
    ('Welcome new leads','New Lead','log_note','Auto: send welcome WhatsApp', 1, true, now()-interval '40 days', now()-interval '40 days'),
    ('Chase payment','Payment Pending','create_task','Call to collect payment', 24, true, now()-interval '30 days', now()-interval '30 days');

  -- ===== CRM: Forms + submissions =====
  INSERT INTO forms (slug, name, fields, enabled, created_at) VALUES
    ('free-webinar','Free Webinar Registration','["Name","Email","Phone","City"]', true, now()-interval '30 days');
  SELECT id INTO frm1 FROM forms WHERE slug='free-webinar';
  INSERT INTO form_submissions (form_id, lead_id, data, created_at) VALUES
    (frm1, NULL,'{"Name":"Meera Joshi","Email":"meera.joshi@example.com","Phone":"+91 90001 00000","City":"Pune"}', now()-interval '1 day'),
    (frm1, NULL,'{"Name":"Kabir Nair","Email":"kabir.nair@example.com","Phone":"+91 90000 77777","City":"Kochi"}', now()-interval '6 days');

  -- ===== AMBASSADOR portal (ambassador@ test user) =====
  IF amb IS NOT NULL THEN
    INSERT INTO ambassador_profiles (user_id, code, tier, created_at)
      VALUES (amb,'TESTAMB','gold', now()-interval '60 days') ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO referrals (ambassador_id, name, email, phone, status, reward_paise, notes, created_at, updated_at) VALUES
      (amb,'Sahil Khan','sahil.k@example.com','+91 90100 11111','rewarded', 100000,'Enrolled in May', now()-interval '35 days', now()-interval '30 days'),
      (amb,'Pooja Das','pooja.d@example.com','+91 90100 22222','enrolled', 0,'Joined June cohort', now()-interval '12 days', now()-interval '5 days'),
      (amb,'Rahul Bose','rahul.b@example.com','+91 90100 33333','contacted', 0,'Counsellor following up', now()-interval '6 days', now()-interval '4 days'),
      (amb,'Tara Menon','tara.m@example.com','+91 90100 44444','new', 0,'', now()-interval '2 days', now()-interval '2 days');
  END IF;

  -- ===== ACCOUNTS portal: ledger + expenses (employee@) =====
  INSERT INTO ledger_entries (kind, category, amount, description, entry_date, created_by, created_at) VALUES
    ('income','Course fees', 9900000,'Aarav — Full-Stack', (now()-interval '36 days')::date, adm, now()-interval '36 days'),
    ('income','Corporate', 15000000,'Acme advance', (now()-interval '6 days')::date, adm, now()-interval '6 days'),
    ('expense','Rent', 6000000,'Office rent — May', (now()-interval '30 days')::date, adm, now()-interval '30 days'),
    ('expense','Marketing', 2500000,'Google Ads', (now()-interval '20 days')::date, adm, now()-interval '20 days'),
    ('expense','Salaries', 9000000,'Mentor payouts', (now()-interval '10 days')::date, adm, now()-interval '10 days');
  IF emp IS NOT NULL THEN
    INSERT INTO acct_expenses (expense_date, vendor, category, amount, gst_amount, status, notes, created_by, created_at, updated_at) VALUES
      ((now()-interval '12 days')::date,'Uber','Travel', 120000, 0,'paid','Client visit', emp, now()-interval '12 days', now()-interval '10 days'),
      ((now()-interval '6 days')::date,'Amazon','Office supplies', 340000, 61200,'approved','Stationery + cables', emp, now()-interval '6 days', now()-interval '4 days'),
      ((now()-interval '2 days')::date,'Zomato','Team lunch', 280000, 0,'pending','Sprint celebration', emp, now()-interval '2 days', now()-interval '2 days');
  END IF;

  -- ===== COLLEGE portal =====
  INSERT INTO colleges (name, contact_person, email, phone, city, mou_status, notes, status, created_at, updated_at) VALUES
    ('St. Xavier''s College','Dr. Fernandes','tpo@xaviers.edu','+91 90200 11111','Mumbai','signed','Active placement partner','active', now()-interval '70 days', now()-interval '5 days'),
    ('VIT Vellore','Prof. Raman','placements@vit.ac.in','+91 90200 22222','Vellore','signed','3 cohorts running','active', now()-interval '50 days', now()-interval '8 days'),
    ('NIT Trichy','Ms. Lakshmi','tnp@nitt.edu','+91 90200 33333','Trichy','draft','MOU under review','active', now()-interval '15 days', now()-interval '3 days');
  SELECT id INTO col1 FROM colleges WHERE name='St. Xavier''s College';
  SELECT id INTO col2 FROM colleges WHERE name='VIT Vellore';
  INSERT INTO college_cohorts (college_id, name, year, students, placed, status, notes, created_at) VALUES
    (col1,'CSE 2024', 2024, 60, 52,'completed','Great placement rate', now()-interval '60 days'),
    (col1,'CSE 2025', 2025, 80, 18,'active','Ongoing', now()-interval '20 days'),
    (col2,'IT 2025', 2025, 120, 30,'active','', now()-interval '40 days'),
    (col2,'ECE 2025', 2025, 90, 0,'planned','Starts next month', now()-interval '5 days');

  -- ===== FRANCHISE portal (franchise@ test user) =====
  IF fr IS NOT NULL THEN
    INSERT INTO franchise_profiles (user_id, territory, code, revenue_share, status, created_at)
      VALUES (fr,'Hyderabad','HYD01', 20, 'active', now()-interval '60 days') ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO franchise_enrollments (franchise_id, student_name, phone, course, fee_paise, status, notes, created_at, updated_at) VALUES
      (fr,'Sai Teja','+91 90300 11111','Full-Stack', 9900000,'paid','', now()-interval '30 days', now()-interval '28 days'),
      (fr,'Divya Sree','+91 90300 22222','Data Science', 8900000,'paid','', now()-interval '22 days', now()-interval '20 days'),
      (fr,'Manoj Kumar','+91 90300 33333','Full-Stack', 9900000,'enrolled','Fee in EMI', now()-interval '10 days', now()-interval '8 days'),
      (fr,'Lavanya P','+91 90300 44444','UI/UX', 6900000,'enrolled','', now()-interval '4 days', now()-interval '4 days'),
      (fr,'Imran Ali','+91 90300 55555','Data Science', 8900000,'dropped','Refunded', now()-interval '18 days', now()-interval '15 days');
  END IF;

  RAISE NOTICE 'demo data seeded successfully';
END $$;
