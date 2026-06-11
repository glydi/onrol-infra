-- LMS demo data on a realistic timeline, for the test student (student@onrol.test),
-- authored by the test mentor (mentor@onrol.test). Idempotent (sentinel-guarded).
-- Two enrolled courses (one in-progress, one completed w/ certificate) + one
-- explorable course, with lessons, progress, quizzes, live classes, announcements.

DO $$
DECLARE
  mentor uuid; stu uuid;
  c1 uuid; c2 uuid; c3 uuid;
  m1 uuid; m2 uuid; m3 uuid; m4 uuid; m5 uuid; m6 uuid; m7 uuid;
  quiz1 uuid;
BEGIN
  SELECT id INTO mentor FROM users WHERE email='mentor@onrol.test';
  SELECT id INTO stu    FROM users WHERE email='student@onrol.test';
  IF stu IS NULL THEN RAISE NOTICE 'no test student — skipping LMS seed'; RETURN; END IF;

  IF EXISTS (SELECT 1 FROM courses WHERE title='Full-Stack Web Development') THEN
    RAISE NOTICE 'LMS demo already seeded — skipping'; RETURN;
  END IF;

  -- ===== Courses =====
  INSERT INTO courses (title, description, owner_id, status, enroll_type, created_at) VALUES
    ('Full-Stack Web Development','Build modern web apps end-to-end with HTML, CSS, JavaScript and React.', mentor,'published','manual', now()-interval '50 days')
    RETURNING id INTO c1;
  INSERT INTO courses (title, description, owner_id, status, enroll_type, created_at) VALUES
    ('Data Science Foundations','Python, pandas and machine-learning basics for aspiring data scientists.', mentor,'published','manual', now()-interval '70 days')
    RETURNING id INTO c2;
  INSERT INTO courses (title, description, owner_id, status, enroll_type, created_at) VALUES
    ('UI/UX Design Essentials','Design thinking, wireframing and Figma for product interfaces.', mentor,'published','self', now()-interval '15 days')
    RETURNING id INTO c3;

  -- ===== Modules + lessons =====
  -- C1: Full-Stack (8 lessons across 3 modules)
  INSERT INTO modules (course_id, title, position) VALUES (c1,'HTML & CSS',0) RETURNING id INTO m1;
  INSERT INTO modules (course_id, title, position) VALUES (c1,'JavaScript',1) RETURNING id INTO m2;
  INSERT INTO modules (course_id, title, position) VALUES (c1,'React',2) RETURNING id INTO m3;
  INSERT INTO lessons (module_id, title, type, body, position) VALUES
    (m1,'Intro to HTML','text','HTML is the backbone of every web page...',0),
    (m1,'CSS Basics','text','Style your pages with selectors, the box model and colors...',1),
    (m1,'Flexbox & Grid','link','https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout',2),
    (m2,'JavaScript Fundamentals','text','Variables, types, functions and control flow...',0),
    (m2,'The DOM','text','Select and manipulate elements, handle events...',1),
    (m2,'Async JavaScript','text','Promises, async/await and fetch...',2),
    (m3,'React Intro','text','Components, JSX and props...',0),
    (m3,'Hooks','text','useState, useEffect and custom hooks...',1);

  -- C2: Data Science (4 lessons across 2 modules)
  INSERT INTO modules (course_id, title, position) VALUES (c2,'Python',0) RETURNING id INTO m4;
  INSERT INTO modules (course_id, title, position) VALUES (c2,'Machine Learning',1) RETURNING id INTO m5;
  INSERT INTO lessons (module_id, title, type, body, position) VALUES
    (m4,'Python Basics','text','Syntax, data structures and functions...',0),
    (m4,'Pandas','text','DataFrames, indexing and aggregation...',1),
    (m5,'Intro to ML','text','Supervised vs unsupervised learning...',0),
    (m5,'Linear Regression','text','Fitting a line, loss and gradient descent...',1);

  -- C3: UI/UX (2 lessons)
  INSERT INTO modules (course_id, title, position) VALUES (c3,'Foundations',0) RETURNING id INTO m6;
  INSERT INTO modules (course_id, title, position) VALUES (c3,'Figma',1) RETURNING id INTO m7;
  INSERT INTO lessons (module_id, title, type, body, position) VALUES
    (m6,'Design Thinking','text','Empathize, define, ideate, prototype, test...',0),
    (m7,'Figma Basics','link','https://help.figma.com/',0);

  -- ===== Enrollments =====
  -- Student: C1 in progress (enrolled 20d ago), C2 completed (enrolled 45d, done 10d).
  INSERT INTO course_enrollments (course_id, user_id, status, enrolled_by, enrolled_at) VALUES
    (c1, stu,'active', mentor, now()-interval '20 days');
  INSERT INTO course_enrollments (course_id, user_id, status, enrolled_by, enrolled_at, completed_at) VALUES
    (c2, stu,'completed', mentor, now()-interval '45 days', now()-interval '10 days');

  -- ===== Lesson progress (timeline-spread) =====
  -- C1: first 5 of 8 lessons done (62%).
  INSERT INTO lesson_progress (user_id, lesson_id, completed_at)
  SELECT stu, x.id, now() - ((20 - x.rn*3) || ' days')::interval
  FROM (SELECT l.id, row_number() OVER (ORDER BY m.position, l.position) rn
        FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=c1) x
  WHERE x.rn <= 5;
  -- C2: all 4 lessons done.
  INSERT INTO lesson_progress (user_id, lesson_id, completed_at)
  SELECT stu, l.id, now()-interval '11 days'
  FROM lessons l JOIN modules m ON m.id=l.module_id WHERE m.course_id=c2;

  -- ===== Certificate for the completed course =====
  INSERT INTO certificates (user_id, course_id, serial, issued_at)
    VALUES (stu, c2,'ONROL-DS-2026-0042', now()-interval '10 days') ON CONFLICT DO NOTHING;

  -- ===== Assessments (quizzes/assignments, day-numbered) =====
  INSERT INTO assessments (course_id, title, type, max_score, day_number, is_published, due_at, created_by, created_at) VALUES
    (c1,'Quiz 1: HTML & CSS','quiz', 100, 1, true, now()+interval '5 days', mentor, now()-interval '18 days')
    RETURNING id INTO quiz1;
  INSERT INTO assessments (course_id, title, type, max_score, day_number, is_published, due_at, created_by, created_at) VALUES
    (c1,'Assignment 1: Build a Portfolio','assignment', 100, 3, true, now()+interval '10 days', mentor, now()-interval '16 days'),
    (c1,'Quiz 2: JavaScript','quiz', 100, 5, true, now()+interval '14 days', mentor, now()-interval '12 days'),
    (c2,'Final Project: ML Model','assignment', 100, 7, true, now()-interval '15 days', mentor, now()-interval '40 days');

  INSERT INTO questions (assessment_id, prompt, type, options, correct, points, position) VALUES
    (quiz1,'Which tag creates a hyperlink?','mcq','["<a>","<link>","<href>","<p>"]','<a>', 1, 0),
    (quiz1,'CSS stands for?','mcq','["Cascading Style Sheets","Computer Style Sheets","Creative Style System","Colorful Style Sheets"]','Cascading Style Sheets', 1, 1),
    (quiz1,'Flexbox is used for?','mcq','["Layout","Database","Networking","Encryption"]','Layout', 1, 2);

  -- ===== Live classes (upcoming) =====
  INSERT INTO class_sessions (course_id, title, starts_at, ends_at, join_url, instructor_id, created_at) VALUES
    (c1,'Live: React Q&A', now()+interval '2 days', now()+interval '2 days 1 hour','https://meet.example.com/onrol-react-qa', mentor, now()-interval '5 days'),
    (c1,'Live: Project Review', now()+interval '9 days', now()+interval '9 days 1 hour','https://meet.example.com/onrol-project-review', mentor, now()-interval '3 days'),
    (c2,'Live: Career in Data Science', now()+interval '4 days', now()+interval '4 days 1 hour','https://meet.example.com/onrol-ds-career', mentor, now()-interval '2 days');

  -- ===== Announcements (course + global) =====
  INSERT INTO announcements (course_id, author_id, title, body, audience, created_at) VALUES
    (c1, mentor,'Welcome to Full-Stack!','Your cohort starts now — complete Module 1 this week.','all', now()-interval '20 days');
  INSERT INTO announcements (author_id, title, body, audience, created_at) VALUES
    (mentor,'New live session added','A React Q&A is scheduled for this week. See Live Classes.','all', now()-interval '5 days');

  RAISE NOTICE 'LMS demo seeded successfully';
END $$;
