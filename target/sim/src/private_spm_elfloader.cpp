// SPDX-License-Identifier: Apache-2.0
#include "elfloader.cpp"
#include <fstream>
#include <iterator>

// Reuse the existing DPI iterator, retaining zero-only PT_LOAD segments.
extern "C" char spm_read_elf(const char *filename) {
  sections.clear();
  mems.clear();
  section_index = 0;
  entry = 0;
  std::ifstream stream(filename, std::ios::binary);
  if (!stream) {
    printf("Error: cannot open SPM ELF %s\n", filename);
    return -1;
  }
  std::vector<char> bytes((std::istreambuf_iterator<char>(stream)),
                          std::istreambuf_iterator<char>());
  Elf64_Ehdr header;
  if (bytes.size() < sizeof(header)) return -1;
  std::memcpy(&header, bytes.data(), sizeof(header));
  if (!IS_ELF64(header) || header.e_ident[5] != 1 || header.e_machine != 243 ||
      header.e_phentsize != sizeof(Elf64_Phdr) || !header.e_phnum ||
      header.e_phoff > bytes.size() ||
      header.e_phnum > (bytes.size()-header.e_phoff)/sizeof(Elf64_Phdr) ||
      header.e_entry < 0x10000000ULL || header.e_entry >= 0x10010000ULL) {
    printf("Error: malformed/non-SPM RV64 ELF %s\n", filename);
    return -1;
  }
  entry = header.e_entry;
  for (unsigned i=0; i<header.e_phnum; ++i) {
    Elf64_Phdr segment;
    std::memcpy(&segment, bytes.data()+header.e_phoff+i*sizeof(segment), sizeof(segment));
    if (segment.p_type != PT_LOAD || !segment.p_memsz) continue;
    if (segment.p_paddr < 0x10000000ULL || segment.p_paddr >= 0x10010000ULL ||
        segment.p_memsz > 0x10010000ULL-segment.p_paddr ||
        segment.p_vaddr != segment.p_paddr || segment.p_filesz > segment.p_memsz ||
        segment.p_offset > bytes.size() || segment.p_filesz > bytes.size()-segment.p_offset) {
      printf("Error: PT_LOAD outside program area or ELF bounds %s\n", filename);
      return -1;
    }
    for (const auto &prior : sections) {
      if (segment.p_paddr < prior.first+prior.second &&
          prior.first < segment.p_paddr+segment.p_memsz) {
        printf("Error: overlapping SPM PT_LOADs %s\n", filename);
        return -1;
      }
    }
    sections.emplace_back(segment.p_paddr, segment.p_memsz);
    mems.emplace(segment.p_paddr,
      std::vector<uint8_t>(bytes.begin()+segment.p_offset,
                           bytes.begin()+segment.p_offset+segment.p_filesz));
  }
  if (sections.empty()) return -1;
  printf("SPM ELF %s entry=%llx PT_LOADs=%zu\n", filename,
         static_cast<unsigned long long>(entry), sections.size());
  return 0;
}
