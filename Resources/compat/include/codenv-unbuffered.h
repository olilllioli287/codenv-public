// codenv:F10 編譯時自動加進來(g++ -include),讓輸出不等換行就馬上顯示
// 沒有這個的話,cout << "..." 後面沒接 endl 的文字會先存著,
// 遇到 system("pause") 會顯示在「請按任意鍵繼續」後面,程式當掉時甚至整段不見
#include <cstdio>
namespace {
struct CodenvUnbuffered {
	CodenvUnbuffered() { std::setvbuf(stdout, nullptr, _IONBF, 0); }
} codenv_unbuffered;
}
