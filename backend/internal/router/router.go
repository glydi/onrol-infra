// Package router wires routes to handlers and applies global middleware.
package router

import (
	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/onrol/lms-backend/internal/auth"
	"github.com/onrol/lms-backend/internal/handlers"
	"github.com/onrol/lms-backend/internal/middleware"
)

func Setup(app *fiber.App, h *handlers.Handlers, jwtm *auth.Manager, pool *pgxpool.Pool) {
	app.Get("/healthz", h.Healthz)

	api := app.Group("/api/v1")

	// Public. Self-registration is intentionally NOT exposed — accounts are
	// created by admins/managers (/admin/users, /manage/users) or enrolment flows.
	api.Post("/auth/login", h.Login)
	api.Post("/auth/forgot", h.ForgotPassword)        // email an OTP to reset the password
	api.Post("/auth/reset", h.ResetPassword)          // verify OTP + set a new password
	api.Post("/forms/:slug/submit", h.SubmitForm)     // public hosted-form intake
	api.Post("/surveys/:slug/submit", h.SubmitSurvey) // public survey intake
	api.Get("/news", h.News)                          // live AI/tech news (RSS aggregate)
	api.Get("/certificates/:serial", h.CertificatePage) // public, printable certificate / verify page

	// Per-route middleware (NOT an empty-prefix group: that would mount the
	// auth middleware at /api/v1 and leak onto the admin routes too).
	auth := middleware.RequireAuth(jwtm, pool)
	// Token-only (no X-Device-UUID header check): the in-browser player fetches
	// HLS keys itself via hls.js, which can't attach our device header.
	tokenAuth := middleware.RequireToken(jwtm)
	api.Get("/devices", auth, h.ListDevices) // view-only: users can't revoke their own devices (admins do)
	api.Patch("/devices/:id", auth, h.RenameDevice) // name your own device
	api.Get("/hls/key/:video_id", tokenAuth, h.HLSKey)
	api.Post("/live/:webinar_id/join", auth, h.LiveJoin)

	// Admin (shared-secret header). Disabled if ADMIN_API_KEY is unset.
	admin := middleware.RequireAdmin(h.Cfg.AdminAPIKey)
	api.Post("/admin/videos", admin, h.CreateVideo)
	api.Post("/admin/webinars", admin, h.CreateWebinar)
	api.Post("/admin/enroll", admin, h.EnrollUser)
	// Bootstrap an LMS manager/instructor without a prior login.
	api.Post("/admin/users", admin, h.CreateManagedUser)
	// Bulk delete all courses (admin key, irreversible).
	api.Delete("/admin/courses", admin, h.AdminDeleteAllCourses)

	// Role gates (each runs after RequireAuth, which loads the role).
	mgr := middleware.RequireRole("manager")
	inst := middleware.RequireRole("instructor")
	ambassador := middleware.RequireAnyRole("ambassador")
	employee := middleware.RequireAnyRole("employee")
	franchise := middleware.RequireAnyRole("franchise_partner")

	// ---- Manager: user & group management --------------------------------
	api.Get("/manage/users", auth, mgr, h.ListUsers)
	api.Post("/manage/users", auth, mgr, h.CreateManagedUser)
	api.Post("/manage/users/batch-assign", auth, mgr, h.AssignBatch)
	api.Post("/manage/users/auto-batch", auth, mgr, h.AutoBatch)
	api.Get("/manage/users/:id/converted-lead", auth, mgr, h.UserConvertedLead)
	api.Get("/manage/converted-leads", auth, mgr, h.ConvertedLeads)
	api.Get("/manage/converted-leads/:leadId", auth, mgr, h.ConvertedLeadDetail)
	api.Delete("/manage/converted-leads/:leadId", auth, mgr, h.DeleteConvertedLead)

	// ---- Video store (R2-backed media library) ---------------------------
	api.Get("/manage/videos", auth, mgr, h.ListVideos)
	api.Post("/manage/videos/upload", auth, mgr, h.UploadVideo)
	api.Post("/manage/videos/upload/init", auth, mgr, h.InitVideoUpload)
	api.Post("/manage/videos/upload/sign", auth, mgr, h.SignUploadParts)
	api.Post("/manage/videos/upload/part", auth, mgr, h.UploadVideoPart)
	api.Post("/manage/videos/upload/complete", auth, mgr, h.CompleteVideoUpload)
	api.Post("/manage/videos/:id/retranscode", auth, mgr, h.RetranscodeVideo)
	api.Delete("/manage/videos/:id", auth, mgr, h.DeleteVideo)
	api.Post("/manage/users/:id/role", auth, mgr, h.SetUserRole)
	api.Post("/manage/users/:id/password", auth, mgr, h.ResetUserPassword)
	api.Post("/manage/users/:id/batch", auth, mgr, h.SetUserBatch)
	api.Delete("/manage/users/:id", auth, mgr, h.DeactivateUser)
	api.Delete("/manage/users/:id/permanent", auth, mgr, h.PurgeUser)
	// Device control: see/revoke a user's bound devices, or reset all (free slots).
	api.Get("/manage/users/:id/devices", auth, mgr, h.AdminListUserDevices)
	api.Delete("/manage/users/:id/devices/:deviceId", auth, mgr, h.AdminRevokeUserDevice)
	api.Delete("/manage/users/:id/devices", auth, mgr, h.AdminResetUserDevices)
	api.Post("/manage/groups", auth, mgr, h.CreateGroup)
	api.Post("/manage/groups/:id/members", auth, mgr, h.AddGroupMember)
	api.Post("/manage/groups/:id/batch-enroll", auth, mgr, h.BatchEnrollGroup)

	// ---- Instructor+: courses, content, assessments, reports, scheduling --
	api.Get("/manage/categories", auth, inst, h.ListCategories)
	api.Post("/manage/categories", auth, inst, h.CreateCategory)
	api.Get("/manage/instructors", auth, inst, h.ListInstructors)
	api.Get("/manage/courses", auth, inst, h.ListCourses)
	api.Post("/manage/courses", auth, mgr, h.CreateCourse) // only admin/manager creates courses
	api.Get("/manage/courses/:id", auth, inst, h.GetManagedCourse)
	api.Patch("/manage/courses/:id", auth, inst, h.UpdateCourse)
	api.Delete("/manage/courses/:id", auth, inst, h.DeleteCourse)
	api.Post("/manage/courses/:id/modules", auth, inst, h.AddModule)
	api.Patch("/manage/modules/:id", auth, inst, h.UpdateModule)
	api.Delete("/manage/modules/:id", auth, inst, h.DeleteModule)
	api.Post("/manage/modules/:id/lessons", auth, inst, h.AddLesson)
	api.Patch("/manage/lessons/:id", auth, inst, h.UpdateLesson)
	api.Delete("/manage/lessons/:id", auth, inst, h.DeleteLesson)
	api.Post("/manage/courses/:id/prerequisites", auth, inst, h.AddPrerequisite)
	api.Post("/manage/courses/:id/enroll", auth, inst, h.ManualEnroll)
	api.Get("/manage/courses/:id/comments", auth, inst, h.ListCourseComments)
	api.Get("/manage/courses/:id/assessments", auth, inst, h.ListCourseAssessments)
	api.Post("/manage/courses/:id/assessments", auth, inst, h.CreateAssessment)
	api.Get("/manage/assessments/:id/questions", auth, inst, h.ListQuestions)
	api.Post("/manage/assessments/:id/questions", auth, inst, h.AddQuestion)
	api.Post("/manage/assessments/:id/generate", auth, inst, h.GenerateQuizQuestions) // AI-drafted questions
	api.Patch("/manage/assessments/:id", auth, inst, h.UpdateAssessment)
	api.Patch("/manage/questions/:id", auth, inst, h.UpdateQuestion)
	api.Delete("/manage/questions/:id", auth, inst, h.DeleteQuestion)
	api.Delete("/manage/assessments/:id", auth, inst, h.DeleteAssessment)
	api.Get("/manage/assessments/:id/submissions", auth, inst, h.ListSubmissions)
	api.Post("/manage/submissions/:id/grade", auth, inst, h.GradeSubmission)
	// Community forum (Discord-like servers/channels) — staff manage.
	api.Get("/manage/community/servers", auth, inst, h.ListForumServers)
	api.Post("/manage/community/servers", auth, inst, h.CreateForumServer)
	api.Delete("/manage/community/servers/:id", auth, inst, h.DeleteForumServer)
	api.Post("/manage/community/servers/:id/channels", auth, inst, h.AddForumChannel)
	api.Delete("/manage/community/channels/:id", auth, inst, h.DeleteForumChannel)

	// Study Hub material (course-scoped, instructor-edited).
	api.Get("/manage/courses/:id/study", auth, inst, h.ListCourseStudy)
	api.Post("/manage/courses/:id/study", auth, inst, h.AddStudyMaterial)
	api.Post("/manage/courses/:id/study/generate", auth, inst, h.GenerateStudyMaterial) // Groq-drafted material
	api.Patch("/manage/study/:id", auth, inst, h.UpdateStudyMaterial)
	api.Delete("/manage/study/:id", auth, inst, h.DeleteStudyMaterial)
	api.Get("/manage/courses/:id/report/completion", auth, inst, h.CompletionReport)
	api.Get("/manage/courses/:id/report/grades", auth, inst, h.GradesReport)
	api.Get("/manage/courses/:id/report/attendance", auth, inst, h.AttendanceReport)
	api.Post("/manage/announcements", auth, inst, h.CreateAnnouncement)
	// Admin calendar: view / add / edit / delete events (surface on student calendars).
	api.Get("/manage/calendar", auth, mgr, h.ListCalendarEvents)
	api.Get("/manage/calendar/feed", auth, mgr, h.ManageCalendarFeed)
	api.Post("/manage/calendar", auth, mgr, h.CreateCalendarEvent)
	api.Delete("/manage/calendar/history", auth, mgr, h.ClearCalendarHistory) // before :id so it isn't swallowed
	api.Patch("/manage/calendar/:id", auth, mgr, h.UpdateCalendarEvent)
	api.Delete("/manage/calendar/:id", auth, mgr, h.DeleteCalendarEvent)
	api.Get("/manage/courses/:id/students", auth, inst, h.ListCourseStudents)
	api.Get("/manage/courses/:id/batches", auth, inst, h.CourseBatches)
	api.Get("/manage/courses/:id/certificates", auth, inst, h.ListCourseCertificates)
	api.Post("/manage/courses/:id/certificates", auth, inst, h.IssueCertificates)
	api.Delete("/manage/courses/:id/certificates/:userId", auth, inst, h.RevokeCertificate)
	api.Get("/manage/enrollment-requests", auth, inst, h.ListEnrollmentRequests)
	api.Post("/manage/enrollment-requests/:id/:action", auth, inst, h.DecideEnrollmentRequest)
	api.Get("/manage/courses/:id/sessions", auth, inst, h.ListCourseSessions)
	api.Post("/manage/courses/:id/sessions", auth, inst, h.CreateSession)
	api.Patch("/manage/sessions/:id", auth, inst, h.UpdateSession)
	api.Delete("/manage/sessions/:id", auth, inst, h.DeleteSession)
	api.Post("/manage/sessions/:id/attendance", auth, inst, h.MarkAttendance)
	api.Get("/manage/announcements", auth, inst, h.ListAnnouncements)
	api.Delete("/manage/announcements/:id", auth, inst, h.DeleteAnnouncement)

	// ---- CRM: admins only (manager / superadmin) -------------------------
	api.Get("/manage/crm/leads", auth, mgr, h.ListLeads)
	api.Post("/manage/crm/leads", auth, mgr, h.CreateLead)
	api.Patch("/manage/crm/leads/:id", auth, mgr, h.UpdateLead)
	api.Post("/manage/crm/leads/:id/status", auth, mgr, h.SetLeadStatus)
	api.Delete("/manage/crm/leads/:id", auth, mgr, h.DeleteLead)
	api.Get("/manage/crm/leads/:id/activities", auth, mgr, h.ListLeadActivities)
	api.Post("/manage/crm/leads/:id/activities", auth, mgr, h.AddLeadActivity)
	api.Get("/manage/crm/leads/:id/tasks", auth, mgr, h.ListLeadTasks)
	api.Post("/manage/crm/leads/:id/tasks", auth, mgr, h.AddLeadTask)
	api.Post("/manage/crm/tasks/:taskId/status", auth, mgr, h.CompleteLeadTask)
	// CRM accounts
	api.Get("/manage/crm/accounts", auth, mgr, h.ListAccounts)
	api.Post("/manage/crm/accounts", auth, mgr, h.CreateAccount)
	api.Patch("/manage/crm/accounts/:id", auth, mgr, h.UpdateAccount)
	api.Delete("/manage/crm/accounts/:id", auth, mgr, h.DeleteAccount)
	// CRM deals
	api.Get("/manage/crm/deals", auth, mgr, h.ListDeals)
	api.Post("/manage/crm/deals", auth, mgr, h.CreateDeal)
	api.Patch("/manage/crm/deals/:id", auth, mgr, h.UpdateDeal)
	api.Delete("/manage/crm/deals/:id", auth, mgr, h.DeleteDeal)
	// CRM broadcasts (campaigns)
	api.Get("/manage/crm/broadcasts", auth, mgr, h.ListBroadcasts)
	api.Post("/manage/crm/broadcasts", auth, mgr, h.CreateBroadcast)
	api.Post("/manage/crm/broadcasts/:id/send", auth, mgr, h.SendBroadcast)
	api.Delete("/manage/crm/broadcasts/:id", auth, mgr, h.DeleteBroadcast)
	// CRM invoices + payments
	api.Get("/manage/crm/invoices", auth, mgr, h.ListInvoices)
	api.Post("/manage/crm/invoices", auth, mgr, h.CreateInvoice)
	api.Post("/manage/crm/invoices/:id/status", auth, mgr, h.SetInvoiceStatus)
	api.Delete("/manage/crm/invoices/:id", auth, mgr, h.DeleteInvoice)
	api.Get("/manage/crm/invoices/:id/payments", auth, mgr, h.ListInvoicePayments)
	api.Post("/manage/crm/invoices/:id/payments", auth, mgr, h.RecordPayment)
	// CRM forms
	api.Get("/manage/crm/forms", auth, mgr, h.ListForms)
	api.Post("/manage/crm/forms", auth, mgr, h.CreateForm)
	api.Delete("/manage/crm/forms/:id", auth, mgr, h.DeleteForm)
	api.Get("/manage/crm/forms/:id/submissions", auth, mgr, h.ListFormSubmissions)
	// CRM batch 2: analytics, automation, surveys, reviews, calendar, feed, tickets, webhooks, affiliates
	api.Get("/manage/crm/analytics", auth, mgr, h.CrmAnalytics)
	api.Get("/manage/crm/automation", auth, mgr, h.ListAutomationRules)
	api.Post("/manage/crm/automation", auth, mgr, h.CreateAutomationRule)
	api.Post("/manage/crm/automation/:id/toggle", auth, mgr, h.ToggleAutomationRule)
	api.Delete("/manage/crm/automation/:id", auth, mgr, h.DeleteAutomationRule)
	api.Get("/manage/crm/surveys", auth, mgr, h.ListSurveys)
	api.Post("/manage/crm/surveys", auth, mgr, h.CreateSurvey)
	api.Delete("/manage/crm/surveys/:id", auth, mgr, h.DeleteSurvey)
	api.Get("/manage/crm/surveys/:id/responses", auth, mgr, h.ListSurveyResponses)
	api.Get("/manage/crm/reviews", auth, mgr, h.ListReviews)
	api.Post("/manage/crm/reviews", auth, mgr, h.CreateReview)
	api.Post("/manage/crm/reviews/:id/status", auth, mgr, h.SetReviewStatus)
	api.Delete("/manage/crm/reviews/:id", auth, mgr, h.DeleteReview)
	api.Get("/manage/crm/events", auth, mgr, h.ListEvents)
	api.Post("/manage/crm/events", auth, mgr, h.CreateEvent)
	api.Delete("/manage/crm/events/:id", auth, mgr, h.DeleteEvent)
	api.Get("/manage/crm/feed", auth, mgr, h.ListFeed)
	api.Post("/manage/crm/feed", auth, mgr, h.CreateFeedPost)
	api.Delete("/manage/crm/feed/:id", auth, mgr, h.DeleteFeedPost)
	api.Get("/manage/crm/tickets", auth, mgr, h.ListTickets)
	api.Post("/manage/crm/tickets", auth, mgr, h.CreateTicket)
	api.Post("/manage/crm/tickets/:id/status", auth, mgr, h.SetTicketStatus)
	api.Get("/manage/crm/webhooks", auth, mgr, h.ListWebhooks)
	api.Post("/manage/crm/webhooks", auth, mgr, h.CreateWebhook)
	api.Delete("/manage/crm/webhooks/:id", auth, mgr, h.DeleteWebhook)
	api.Get("/manage/crm/affiliates", auth, mgr, h.ListAffiliates)
	api.Post("/manage/crm/affiliates", auth, mgr, h.CreateAffiliate)
	api.Delete("/manage/crm/affiliates/:id", auth, mgr, h.DeleteAffiliate)
	api.Get("/manage/crm/affiliates/:id/commissions", auth, mgr, h.ListCommissions)
	api.Post("/manage/crm/affiliates/:id/commissions", auth, mgr, h.AddCommission)
	api.Post("/manage/crm/affiliates/:id/commissions/:cid/pay", auth, mgr, h.PayCommission)
	// CRM integrations, funnel, my-day, messaging, payment links
	api.Get("/manage/integrations", auth, mgr, h.ListIntegrations)
	api.Get("/manage/crm/funnel", auth, mgr, h.CrmFunnel)
	api.Get("/manage/crm/my-day", auth, mgr, h.CrmMyDay)
	api.Post("/manage/crm/leads/:id/message", auth, mgr, h.SendLeadMessage)
	api.Post("/manage/crm/invoices/:id/payment-link", auth, mgr, h.CreatePaymentLink)

	// ---- Ambassador portal -----------------------------------------------
	// Admin: manage ambassadors + all referrals.
	api.Get("/manage/ambassadors", auth, mgr, h.ListAmbassadors)
	api.Post("/manage/ambassadors", auth, mgr, h.CreateAmbassador)
	api.Get("/manage/ambassadors/referrals", auth, mgr, h.AdminListReferrals)
	api.Post("/manage/ambassadors/referrals/:id/status", auth, mgr, h.SetReferralStatus)
	// Ambassador self (admins also allowed).
	api.Get("/ambassador/me", auth, ambassador, h.MyAmbassador)
	api.Get("/ambassador/referrals", auth, ambassador, h.MyReferrals)
	api.Post("/ambassador/referrals", auth, ambassador, h.CreateReferral)

	// ---- Accounts & Administration portal --------------------------------
	// Admin: cash ledger, expense approval, staff.
	api.Get("/manage/accounts/ledger", auth, mgr, h.ListLedger)
	api.Post("/manage/accounts/ledger", auth, mgr, h.CreateLedgerEntry)
	api.Delete("/manage/accounts/ledger/:id", auth, mgr, h.DeleteLedgerEntry)
	api.Get("/manage/accounts/expenses", auth, mgr, h.ListAllExpenses)
	api.Post("/manage/accounts/expenses/:id/status", auth, mgr, h.SetExpenseStatus)
	api.Get("/manage/accounts/staff", auth, mgr, h.ListEmployees)
	api.Post("/manage/accounts/staff", auth, mgr, h.CreateEmployee)
	// Employee self (admins also allowed).
	api.Get("/accounts/expenses", auth, employee, h.MyExpenses)
	api.Post("/accounts/expenses", auth, employee, h.SubmitExpense)

	// ---- Franchise Partner portal ----------------------------------------
	// Admin: manage partners + all enrollments.
	api.Get("/manage/franchises", auth, mgr, h.ListFranchises)
	api.Post("/manage/franchises", auth, mgr, h.CreateFranchise)
	api.Get("/manage/franchises/enrollments", auth, mgr, h.AdminListEnrollments)
	api.Post("/manage/franchises/enrollments/:id/status", auth, mgr, h.SetEnrollmentStatus)
	// Franchise self (admins also allowed).
	api.Get("/franchise/me", auth, franchise, h.MyFranchise)
	api.Get("/franchise/enrollments", auth, franchise, h.MyEnrollments)
	api.Post("/franchise/enrollments", auth, franchise, h.CreateEnrollment)

	// ---- College Partner portal (admin + employee) -----------------------
	api.Get("/college/summary", auth, employee, h.CollegeSummary)
	api.Get("/college/colleges", auth, employee, h.ListColleges)
	api.Post("/college/colleges", auth, employee, h.CreateCollege)
	api.Patch("/college/colleges/:id", auth, employee, h.UpdateCollege)
	api.Delete("/college/colleges/:id", auth, employee, h.DeleteCollege)
	api.Get("/college/colleges/:id/cohorts", auth, employee, h.ListCohorts)
	api.Post("/college/colleges/:id/cohorts", auth, employee, h.AddCohort)
	api.Patch("/college/cohorts/:id", auth, employee, h.UpdateCohort)
	api.Delete("/college/cohorts/:id", auth, employee, h.DeleteCohort)

	// ---- Student/self (any authenticated role) ---------------------------
	// Discussion / doubts board (enrolled students + course staff).
	api.Get("/courses/:id/discussion", auth, h.ListDiscussion)
	api.Post("/courses/:id/discussion", auth, h.PostDiscussion)

	api.Get("/catalog", auth, h.Catalog)
	api.Get("/me/profile", auth, h.GetMyProfile)
	api.Get("/me/videos/:id/hls.key", tokenAuth, h.MediaHLSKey) // AES-128 key for encrypted video-store HLS (player fetches via hls.js — no device header)
	api.Patch("/me/profile", auth, h.UpdateMyProfile)
	api.Get("/me/preferences", auth, h.GetPreferences)
	api.Put("/me/preferences", auth, h.UpdatePreferences)
	api.Get("/me/courses", auth, h.MyCourses)
	api.Get("/me/leaderboard", auth, h.MyLeaderboard)
	api.Get("/me/streak", auth, h.MyStreak)
	api.Post("/me/password", auth, h.ChangeMyPassword)
	api.Post("/me/courses/:id/enroll", auth, h.SelfEnroll)
	api.Get("/me/courses/:id/content", auth, h.CourseContent)
	api.Post("/me/courses/:id/forum", auth, h.PostForum)
	api.Get("/me/forum", auth, h.ListForum)
	api.Post("/me/forum", auth, h.CreateForumThread)
	api.Get("/me/forum/:id", auth, h.GetForumThread)
	api.Post("/me/forum/:id/reply", auth, h.ReplyForum)
	api.Delete("/me/forum/:id", auth, h.DeleteForumThread)
	api.Delete("/me/forum/posts/:postId", auth, h.DeleteForumPost)
	// Community forum (Discord-like): servers I can see + channel messages.
	api.Get("/me/community/servers", auth, h.MyForumServers)
	api.Get("/me/community/channels/:id/messages", auth, h.ForumMessages)
	api.Post("/me/community/channels/:id/messages", auth, h.PostForumMessage)
	api.Delete("/me/community/messages/:id", auth, h.DeleteForumMessage)
	api.Post("/me/lessons/:id/complete", auth, h.CompleteLesson)
	api.Post("/me/lessons/:id/progress", auth, h.SaveLessonProgress)
	api.Get("/me/resume", auth, h.ResumeLearning)
	api.Get("/modules/:id/comments", auth, h.ListModuleComments)
	api.Post("/modules/:id/comments", auth, h.PostModuleComment)
	api.Get("/courses/:id/comments", auth, h.ListGeneralComments)
	api.Post("/courses/:id/comments", auth, h.PostGeneralComment)
	api.Get("/me/courses/:id/study", auth, h.MyStudyMaterials)
	api.Get("/me/assessments", auth, h.MyAssessments)
	api.Get("/me/assessments/:id", auth, h.TakeAssessment)
	api.Post("/me/assessments/:id/submit", auth, h.SubmitAssessment)
	api.Post("/me/assessments/:id/files", auth, h.UploadSubmissionFile)
	api.Get("/me/assessments/:id/files", auth, h.ListMySubmissionFiles)
	api.Delete("/me/submission-files/:id", auth, h.DeleteSubmissionFile)
	api.Get("/me/submission-files/:id", auth, h.DownloadSubmissionFile)
	// Personal study notes.
	api.Get("/me/notes", auth, h.MyNotes)
	api.Post("/me/notes", auth, h.CreateNote)
	api.Patch("/me/notes/:id", auth, h.UpdateNote)
	api.Delete("/me/notes/:id", auth, h.DeleteNote)
	api.Get("/me/live", auth, h.MyLive)
	// Simulated-live sessions (a recorded video served as a live stream).
	api.Get("/me/live/:id/state", auth, h.LiveSessionState)
	api.Post("/me/live/:id/heartbeat", auth, h.LiveHeartbeat)
	api.Post("/me/live/:id/react", auth, h.LiveReact)
	api.Post("/me/live/:id/control", auth, h.LiveControl)      // host-only room controls
	api.Get("/me/live/:id/attendance", auth, h.LiveAttendance) // host-only: who watched, how long
	api.Get("/me/live/:id/chat", auth, h.LiveChatList)
	api.Post("/me/live/:id/chat", auth, h.LiveChatPost)
	api.Delete("/me/live/:id/chat/:msgId", auth, h.LiveChatDelete)
	api.Get("/me/live/:id/questions", auth, h.LiveQuestionsList)
	api.Post("/me/live/:id/questions", auth, h.LiveQuestionPost)
	api.Post("/me/live/:id/questions/:qid/answer", auth, h.LiveAnswerQuestion)
	// Playlist + key fetched by hls.js (no device header) → token-auth, enrollment-gated.
	api.Get("/me/live/:id/playlist.m3u8", tokenAuth, h.LivePlaylist)
	api.Get("/me/live/:id/hls.key", tokenAuth, h.LiveHLSKey)
	// Live-host portal: a restricted role that only lists live sessions to host
	// (answer Q&A + watch). Managers/superadmins are allowed by RequireAnyRole.
	api.Get("/live-host/sessions", auth, middleware.RequireAnyRole("live_host"), h.ListLiveHostSessions)
	api.Get("/me/grades", auth, h.MyGrades)
	api.Get("/me/transcript", auth, h.MyTranscript)
	api.Get("/me/certificates", auth, h.MyCertificates)
	api.Get("/me/calendar", auth, h.MyCalendar)
	api.Get("/me/announcements", auth, h.MyAnnouncements)
	api.Get("/me/notifications", auth, h.MyNotifications)
	api.Post("/me/notifications/read", auth, h.MarkNotificationsRead)
	// Self-hosted Web Push: VAPID public key + per-browser subscription.
	api.Get("/push/public-key", auth, h.PushPublicKey)
	api.Post("/me/push/subscribe", auth, h.PushSubscribe)
	api.Post("/me/push/unsubscribe", auth, h.PushUnsubscribe)
	api.Post("/me/messages", auth, h.SendMessage)
	api.Get("/me/messages", auth, h.Inbox)
}

// ErrorHandler renders fiber.Error as JSON and hides internals for 5xx.
func ErrorHandler(c *fiber.Ctx, err error) error {
	code := fiber.StatusInternalServerError
	msg := "internal error"
	if fe, ok := err.(*fiber.Error); ok {
		code = fe.Code
		msg = fe.Message
	}
	return c.Status(code).JSON(fiber.Map{"error": msg})
}
