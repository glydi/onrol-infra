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

	// Public.
	api.Post("/auth/register", h.Register)
	api.Post("/auth/login", h.Login)
	api.Post("/forms/:slug/submit", h.SubmitForm)     // public hosted-form intake
	api.Post("/surveys/:slug/submit", h.SubmitSurvey) // public survey intake

	// Per-route middleware (NOT an empty-prefix group: that would mount the
	// auth middleware at /api/v1 and leak onto the admin routes too).
	auth := middleware.RequireAuth(jwtm, pool)
	api.Get("/devices", auth, h.ListDevices)
	api.Delete("/devices/:id", auth, h.RevokeDevice)
	api.Get("/hls/key/:video_id", auth, h.HLSKey)
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

	// ---- Manager: user & group management --------------------------------
	api.Get("/manage/users", auth, mgr, h.ListUsers)
	api.Post("/manage/users", auth, mgr, h.CreateManagedUser)
	api.Post("/manage/users/:id/role", auth, mgr, h.SetUserRole)
	api.Post("/manage/users/:id/password", auth, mgr, h.ResetUserPassword)
	api.Post("/manage/users/:id/batch", auth, mgr, h.SetUserBatch)
	api.Delete("/manage/users/:id", auth, mgr, h.DeactivateUser)
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
	api.Delete("/manage/modules/:id", auth, inst, h.DeleteModule)
	api.Post("/manage/modules/:id/lessons", auth, inst, h.AddLesson)
	api.Delete("/manage/lessons/:id", auth, inst, h.DeleteLesson)
	api.Post("/manage/courses/:id/prerequisites", auth, inst, h.AddPrerequisite)
	api.Post("/manage/courses/:id/enroll", auth, inst, h.ManualEnroll)
	api.Get("/manage/courses/:id/assessments", auth, inst, h.ListCourseAssessments)
	api.Post("/manage/courses/:id/assessments", auth, inst, h.CreateAssessment)
	api.Post("/manage/assessments/:id/questions", auth, inst, h.AddQuestion)
	api.Get("/manage/assessments/:id/submissions", auth, inst, h.ListSubmissions)
	api.Post("/manage/submissions/:id/grade", auth, inst, h.GradeSubmission)
	api.Get("/manage/courses/:id/report/completion", auth, inst, h.CompletionReport)
	api.Get("/manage/courses/:id/report/grades", auth, inst, h.GradesReport)
	api.Get("/manage/courses/:id/report/attendance", auth, inst, h.AttendanceReport)
	api.Post("/manage/announcements", auth, inst, h.CreateAnnouncement)
	api.Get("/manage/courses/:id/students", auth, inst, h.ListCourseStudents)
	api.Get("/manage/enrollment-requests", auth, inst, h.ListEnrollmentRequests)
	api.Post("/manage/enrollment-requests/:id/:action", auth, inst, h.DecideEnrollmentRequest)
	api.Get("/manage/courses/:id/sessions", auth, inst, h.ListCourseSessions)
	api.Post("/manage/courses/:id/sessions", auth, inst, h.CreateSession)
	api.Patch("/manage/sessions/:id", auth, inst, h.UpdateSession)
	api.Post("/manage/sessions/:id/attendance", auth, inst, h.MarkAttendance)
	api.Get("/manage/announcements", auth, inst, h.ListAnnouncements)

	// ---- CRM: leads pipeline + activities + tasks (instructor+) ----------
	api.Get("/manage/crm/leads", auth, inst, h.ListLeads)
	api.Post("/manage/crm/leads", auth, inst, h.CreateLead)
	api.Patch("/manage/crm/leads/:id", auth, inst, h.UpdateLead)
	api.Post("/manage/crm/leads/:id/status", auth, inst, h.SetLeadStatus)
	api.Delete("/manage/crm/leads/:id", auth, inst, h.DeleteLead)
	api.Get("/manage/crm/leads/:id/activities", auth, inst, h.ListLeadActivities)
	api.Post("/manage/crm/leads/:id/activities", auth, inst, h.AddLeadActivity)
	api.Get("/manage/crm/leads/:id/tasks", auth, inst, h.ListLeadTasks)
	api.Post("/manage/crm/leads/:id/tasks", auth, inst, h.AddLeadTask)
	api.Post("/manage/crm/tasks/:taskId/status", auth, inst, h.CompleteLeadTask)
	// CRM accounts
	api.Get("/manage/crm/accounts", auth, inst, h.ListAccounts)
	api.Post("/manage/crm/accounts", auth, inst, h.CreateAccount)
	api.Patch("/manage/crm/accounts/:id", auth, inst, h.UpdateAccount)
	api.Delete("/manage/crm/accounts/:id", auth, inst, h.DeleteAccount)
	// CRM deals
	api.Get("/manage/crm/deals", auth, inst, h.ListDeals)
	api.Post("/manage/crm/deals", auth, inst, h.CreateDeal)
	api.Patch("/manage/crm/deals/:id", auth, inst, h.UpdateDeal)
	api.Delete("/manage/crm/deals/:id", auth, inst, h.DeleteDeal)
	// CRM broadcasts (campaigns)
	api.Get("/manage/crm/broadcasts", auth, inst, h.ListBroadcasts)
	api.Post("/manage/crm/broadcasts", auth, inst, h.CreateBroadcast)
	api.Post("/manage/crm/broadcasts/:id/send", auth, inst, h.SendBroadcast)
	api.Delete("/manage/crm/broadcasts/:id", auth, inst, h.DeleteBroadcast)
	// CRM invoices + payments
	api.Get("/manage/crm/invoices", auth, inst, h.ListInvoices)
	api.Post("/manage/crm/invoices", auth, inst, h.CreateInvoice)
	api.Post("/manage/crm/invoices/:id/status", auth, inst, h.SetInvoiceStatus)
	api.Delete("/manage/crm/invoices/:id", auth, inst, h.DeleteInvoice)
	api.Get("/manage/crm/invoices/:id/payments", auth, inst, h.ListInvoicePayments)
	api.Post("/manage/crm/invoices/:id/payments", auth, inst, h.RecordPayment)
	// CRM forms
	api.Get("/manage/crm/forms", auth, inst, h.ListForms)
	api.Post("/manage/crm/forms", auth, inst, h.CreateForm)
	api.Delete("/manage/crm/forms/:id", auth, inst, h.DeleteForm)
	api.Get("/manage/crm/forms/:id/submissions", auth, inst, h.ListFormSubmissions)
	// CRM batch 2: analytics, automation, surveys, reviews, calendar, feed, tickets, webhooks, affiliates
	api.Get("/manage/crm/analytics", auth, inst, h.CrmAnalytics)
	api.Get("/manage/crm/automation", auth, inst, h.ListAutomationRules)
	api.Post("/manage/crm/automation", auth, inst, h.CreateAutomationRule)
	api.Post("/manage/crm/automation/:id/toggle", auth, inst, h.ToggleAutomationRule)
	api.Delete("/manage/crm/automation/:id", auth, inst, h.DeleteAutomationRule)
	api.Get("/manage/crm/surveys", auth, inst, h.ListSurveys)
	api.Post("/manage/crm/surveys", auth, inst, h.CreateSurvey)
	api.Delete("/manage/crm/surveys/:id", auth, inst, h.DeleteSurvey)
	api.Get("/manage/crm/surveys/:id/responses", auth, inst, h.ListSurveyResponses)
	api.Get("/manage/crm/reviews", auth, inst, h.ListReviews)
	api.Post("/manage/crm/reviews", auth, inst, h.CreateReview)
	api.Post("/manage/crm/reviews/:id/status", auth, inst, h.SetReviewStatus)
	api.Delete("/manage/crm/reviews/:id", auth, inst, h.DeleteReview)
	api.Get("/manage/crm/events", auth, inst, h.ListEvents)
	api.Post("/manage/crm/events", auth, inst, h.CreateEvent)
	api.Delete("/manage/crm/events/:id", auth, inst, h.DeleteEvent)
	api.Get("/manage/crm/feed", auth, inst, h.ListFeed)
	api.Post("/manage/crm/feed", auth, inst, h.CreateFeedPost)
	api.Delete("/manage/crm/feed/:id", auth, inst, h.DeleteFeedPost)
	api.Get("/manage/crm/tickets", auth, inst, h.ListTickets)
	api.Post("/manage/crm/tickets", auth, inst, h.CreateTicket)
	api.Post("/manage/crm/tickets/:id/status", auth, inst, h.SetTicketStatus)
	api.Get("/manage/crm/webhooks", auth, inst, h.ListWebhooks)
	api.Post("/manage/crm/webhooks", auth, inst, h.CreateWebhook)
	api.Delete("/manage/crm/webhooks/:id", auth, inst, h.DeleteWebhook)
	api.Get("/manage/crm/affiliates", auth, inst, h.ListAffiliates)
	api.Post("/manage/crm/affiliates", auth, inst, h.CreateAffiliate)
	api.Delete("/manage/crm/affiliates/:id", auth, inst, h.DeleteAffiliate)
	api.Get("/manage/crm/affiliates/:id/commissions", auth, inst, h.ListCommissions)
	api.Post("/manage/crm/affiliates/:id/commissions", auth, inst, h.AddCommission)
	api.Post("/manage/crm/affiliates/:id/commissions/:cid/pay", auth, inst, h.PayCommission)

	// ---- Student/self (any authenticated role) ---------------------------
	// Discussion / doubts board (enrolled students + course staff).
	api.Get("/courses/:id/discussion", auth, h.ListDiscussion)
	api.Post("/courses/:id/discussion", auth, h.PostDiscussion)

	api.Get("/catalog", auth, h.Catalog)
	api.Get("/me/profile", auth, h.GetMyProfile)
	api.Patch("/me/profile", auth, h.UpdateMyProfile)
	api.Get("/me/preferences", auth, h.GetPreferences)
	api.Put("/me/preferences", auth, h.UpdatePreferences)
	api.Get("/me/courses", auth, h.MyCourses)
	api.Post("/me/courses/:id/enroll", auth, h.SelfEnroll)
	api.Get("/me/courses/:id/content", auth, h.CourseContent)
	api.Post("/me/courses/:id/forum", auth, h.PostForum)
	api.Post("/me/lessons/:id/complete", auth, h.CompleteLesson)
	api.Get("/me/assessments", auth, h.MyAssessments)
	api.Get("/me/assessments/:id", auth, h.TakeAssessment)
	api.Post("/me/assessments/:id/submit", auth, h.SubmitAssessment)
	api.Get("/me/live", auth, h.MyLive)
	api.Get("/me/grades", auth, h.MyGrades)
	api.Get("/me/transcript", auth, h.MyTranscript)
	api.Get("/me/certificates", auth, h.MyCertificates)
	api.Get("/me/calendar", auth, h.MyCalendar)
	api.Get("/me/announcements", auth, h.MyAnnouncements)
	api.Get("/me/notifications", auth, h.MyNotifications)
	api.Post("/me/notifications/read", auth, h.MarkNotificationsRead)
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
