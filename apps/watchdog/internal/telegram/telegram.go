package telegram

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings" // Added
	"time"
)

type Service struct {
	BotToken string
	ChatID   string
	Queue    chan string
}

func New() *Service {
	// Clean the strings to prevent hidden newlines/spaces breaking the URL
	token := strings.TrimSpace(os.Getenv("TELEGRAM_BOT_TOKEN"))
	chatID := strings.TrimSpace(os.Getenv("TELEGRAM_CHAT_ID"))

	log.Printf("📡 [TELEGRAM] Initializing. Token length: %d chars, ChatID: %s", len(token), chatID)

	return &Service{
		BotToken: token,
		ChatID:   chatID,
		Queue:    make(chan string, 100),
	}
}

func (s *Service) Send(msg string) {
	log.Printf("📢 [WATCHDOG] Outgoing message: %s", msg)
	select {
	case s.Queue <- msg:
	default:
		log.Println("❌ [TELEGRAM] Queue full, dropping message")
	}
}

func (s *Service) StartWorker() {
	log.Println("🚀 [TELEGRAM] Worker started")
	go func() {
		for msg := range s.Queue {
			s.postMessage(msg)
			time.Sleep(200 * time.Millisecond) // Respect Telegram rate limits
		}
	}()
}

func (s *Service) postMessage(text string) {
	if s.BotToken == "" {
		log.Println("❌ [TELEGRAM] Cannot send: TELEGRAM_BOT_TOKEN is empty in environment")
		return
	}

	apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", s.BotToken)
	
	resp, err := http.PostForm(apiURL, url.Values{
		"chat_id": {s.ChatID},
		"text":    {text},
	})

	if err != nil {
		log.Printf("❌ [TELEGRAM] Network Error: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("❌ [TELEGRAM] API Error %d: %s", resp.StatusCode, string(body))
		return
	}

	log.Printf("✅ [TELEGRAM] Message delivered")
}