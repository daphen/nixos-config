// stdin: one swipe per line, "x y t x y t ..." in QWERTY key units (key = 1x1, row 0 at y 0).
#include "swipekb/language_engine.hpp"
#include <iostream>
#include <sstream>
using namespace swipekb;
int main(int argc, char **argv) {
    std::string a = argc > 1 ? argv[1] : ".";
    LanguageEngine e; LanguageEngineSetup s;
    s.language = "en"; s.dictionary = a + "/en_swipe.combined"; s.ngram = a + "/en.ngram"; s.swipeModel = a + "/swipe-model.bin";
    if (!e.init(s)) { std::cerr << "init failed\n"; return 1; }
    std::cerr << "model=" << e.hasModel() << " ngram=" << e.usingNgram() << "\n";
    const char *rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const float off[] = {0, 0.25f, 0.75f};
    const float K = 100;
    std::vector<KeyRect> keys;
    for (int r = 0; r < 3; ++r) for (int i = 0; rows[r][i]; ++i)
        keys.push_back({(char32_t)rows[r][i], (off[r] + i) * K, r * K, K, K});
    std::string line;
    while (std::getline(std::cin, line)) {
        std::istringstream in(line); std::vector<TracePoint> t; float x, y, ms;
        while (in >> x >> y >> ms) t.push_back({x * K, y * K, ms});
        auto g = e.recognize(t, keys, {}, 5);
        for (size_t i = 0; i < g.size(); ++i) std::cout << (i ? " " : "") << g[i].word << ":" << g[i].score;
        std::cout << std::endl;
    }
}
