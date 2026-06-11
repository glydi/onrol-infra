package handlers

import (
	"strings"

	"github.com/gofiber/fiber/v2"
	"golang.org/x/crypto/bcrypt"
)

// =====================================================================
// Accounts & Administration portal — admins run the books + approve
// expenses + manage staff; employees submit their own expenses.
// =====================================================================

// ---- Cash ledger (admin) ---------------------------------------------------

// ListLedger returns ledger entries plus an income / expense / balance summary.
func (h *Handlers) ListLedger(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT l.id, l.kind, l.category, l.amount, l.description, l.entry_date, COALESCE(u.full_name,'')
		FROM ledger_entries l LEFT JOIN users u ON u.id=l.created_by
		ORDER BY l.entry_date DESC, l.created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, kind, category, desc, by string
		var amount int64
		var date any
		if err := rows.Scan(&id, &kind, &category, &amount, &desc, &date, &by); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "kind": kind, "category": category, "amount": amount,
			"description": desc, "entry_date": date, "by": by})
	}
	var income, expense int64
	_ = h.Pool.QueryRow(c.Context(), `SELECT
		COALESCE(sum(amount) FILTER (WHERE kind='income'),0),
		COALESCE(sum(amount) FILTER (WHERE kind='expense'),0) FROM ledger_entries`).Scan(&income, &expense)
	// Add approved+paid expenses to the expense side of the balance.
	var paidExp int64
	_ = h.Pool.QueryRow(c.Context(), `SELECT COALESCE(sum(amount+gst_amount),0) FROM acct_expenses WHERE status='paid'`).Scan(&paidExp)
	return c.JSON(fiber.Map{"entries": out, "income": income, "expense": expense + paidExp,
		"balance": income - expense - paidExp})
}

func (h *Handlers) CreateLedgerEntry(c *fiber.Ctx) error {
	var req struct {
		Kind        string `json:"kind"`
		Category    string `json:"category"`
		Amount      int64  `json:"amount"`
		Description string `json:"description"`
		EntryDate   string `json:"entry_date"`
	}
	if err := c.BodyParser(&req); err != nil || req.Amount <= 0 {
		return fiber.NewError(fiber.StatusBadRequest, "amount (in paise) required")
	}
	if req.Kind != "income" {
		req.Kind = "expense"
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO ledger_entries (kind, category, amount, description, entry_date, created_by)
		 VALUES ($1,$2,$3,$4,COALESCE(NULLIF($5,'')::date, current_date),$6) RETURNING id`,
		req.Kind, req.Category, req.Amount, req.Description, req.EntryDate, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

func (h *Handlers) DeleteLedgerEntry(c *fiber.Ctx) error {
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM ledger_entries WHERE id=$1`, c.Params("id")); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true})
}

// ---- Expenses --------------------------------------------------------------

func scanExpenses(rows interface {
	Next() bool
	Scan(...any) error
}) []fiber.Map {
	out := []fiber.Map{}
	for rows.Next() {
		var id, vendor, category, status, notes, by string
		var amount, gst int64
		var date any
		if err := rows.Scan(&id, &date, &vendor, &category, &amount, &gst, &status, &notes, &by); err != nil {
			continue
		}
		out = append(out, fiber.Map{"id": id, "expense_date": date, "vendor": vendor, "category": category,
			"amount": amount, "gst_amount": gst, "status": status, "notes": notes, "by": by})
	}
	return out
}

// ListAllExpenses — admin view of every expense.
func (h *Handlers) ListAllExpenses(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT e.id, e.expense_date, e.vendor, e.category, e.amount, e.gst_amount, e.status, e.notes,
		       COALESCE(u.full_name,'')
		FROM acct_expenses e LEFT JOIN users u ON u.id=e.created_by
		ORDER BY (e.status<>'pending'), e.created_at DESC LIMIT 1000`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := scanExpenses(rows)
	var pending int64
	_ = h.Pool.QueryRow(c.Context(), `SELECT count(*) FROM acct_expenses WHERE status='pending'`).Scan(&pending)
	return c.JSON(fiber.Map{"expenses": out, "pending": pending})
}

// SetExpenseStatus — admin approves / pays / rejects an expense.
func (h *Handlers) SetExpenseStatus(c *fiber.Ctx) error {
	var req struct {
		Status string `json:"status"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	switch req.Status {
	case "pending", "approved", "paid", "rejected":
	default:
		return fiber.NewError(fiber.StatusBadRequest, "invalid status")
	}
	ct, err := h.Pool.Exec(c.Context(), `UPDATE acct_expenses SET status=$2, updated_at=now() WHERE id=$1`,
		c.Params("id"), req.Status)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "update failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "expense not found")
	}
	return c.JSON(fiber.Map{"id": c.Params("id"), "status": req.Status})
}

// MyExpenses — the caller's own submitted expenses (employee view).
func (h *Handlers) MyExpenses(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT e.id, e.expense_date, e.vendor, e.category, e.amount, e.gst_amount, e.status, e.notes, ''
		FROM acct_expenses e WHERE e.created_by=$1 ORDER BY e.created_at DESC LIMIT 500`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	return c.JSON(fiber.Map{"expenses": scanExpenses(rows)})
}

// SubmitExpense — an employee files a new expense (status pending).
func (h *Handlers) SubmitExpense(c *fiber.Ctx) error {
	var req struct {
		Vendor      string `json:"vendor"`
		Category    string `json:"category"`
		Amount      int64  `json:"amount"`
		GstAmount   int64  `json:"gst_amount"`
		ExpenseDate string `json:"expense_date"`
		Notes       string `json:"notes"`
	}
	if err := c.BodyParser(&req); err != nil || req.Amount <= 0 {
		return fiber.NewError(fiber.StatusBadRequest, "amount (in paise) required")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO acct_expenses (vendor, category, amount, gst_amount, notes, expense_date, created_by)
		 VALUES ($1,$2,$3,$4,$5,COALESCE(NULLIF($6,'')::date, current_date),$7) RETURNING id`,
		req.Vendor, req.Category, req.Amount, req.GstAmount, req.Notes, req.ExpenseDate, callerID(c)).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// ---- Staff (employee accounts) ---------------------------------------------

func (h *Handlers) ListEmployees(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, full_name, email, COALESCE(phone,''), is_active FROM users WHERE role='employee' ORDER BY full_name`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, name, email, phone string
		var active bool
		if err := rows.Scan(&id, &name, &email, &phone, &active); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "full_name": name, "email": email, "phone": phone, "is_active": active})
	}
	return c.JSON(fiber.Map{"employees": out})
}

func (h *Handlers) CreateEmployee(c *fiber.Ctx) error {
	var req struct {
		FullName string `json:"full_name"`
		Email    string `json:"email"`
		Phone    string `json:"phone"`
		Password string `json:"password"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	req.Email = strings.ToLower(strings.TrimSpace(req.Email))
	if req.Email == "" || strings.TrimSpace(req.FullName) == "" || req.Password == "" {
		return fiber.NewError(fiber.StatusBadRequest, "full_name, email, password required")
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	var id string
	err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO users (email, phone, full_name, password_hash, role, max_devices)
		 VALUES ($1,$2,$3,$4,'employee',$5) RETURNING id`,
		req.Email, req.Phone, req.FullName, string(hash), h.Cfg.MaxDevices).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "users_email_key") {
			return fiber.NewError(fiber.StatusConflict, "email already registered")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "create failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}
